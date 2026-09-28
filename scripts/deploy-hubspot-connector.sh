#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-HUBSPOT-01.json"
SYS_WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SYS-01.json"
BASE_CONFIG="$ROOT_DIR/config/hubspot-connector.example.json"
CONFIRMATION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)
      CONFIRMATION="${2:-}"
      shift 2
      ;;
    *)
      echo "FAIL: unknown argument: $1"
      exit 1
      ;;
  esac
done

[[ "$CONFIRMATION" == "REVINT_HUBSPOT_CONNECTOR" ]] || {
  echo "FAIL: HubSpot activation confirmation token is missing or incorrect."
  exit 1
}

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
[[ -f "$WORKFLOW" ]] || { echo "FAIL: HubSpot workflow template is missing."; exit 1; }
[[ -f "$SYS_WORKFLOW" ]] || { echo "FAIL: reliability workflow template is missing."; exit 1; }
[[ -f "$BASE_CONFIG" ]] || { echo "FAIL: HubSpot connector config is missing."; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ "${HUBSPOT_SYNC_ENABLED:-false}" == "true" ]] || {
  echo "FAIL: HUBSPOT_SYNC_ENABLED must be true for activation."
  exit 1
}

required=(
  HUBSPOT_PRIVATE_APP_TOKEN
  REPORTING_DB_ADMIN_USER REPORTING_DB_NAME
  N8N_DB_USER N8N_DB_NAME
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or uses a placeholder."
    exit 1
  fi
done

lookback="${HUBSPOT_INITIAL_LOOKBACK_DAYS:-30}"
overlap="${HUBSPOT_SYNC_OVERLAP_SECONDS:-300}"
[[ "$lookback" =~ ^[0-9]+$ && "$lookback" -ge 1 && "$lookback" -le 3650 ]] || {
  echo "FAIL: HUBSPOT_INITIAL_LOOKBACK_DAYS must be between 1 and 3650."
  exit 1
}
[[ "$overlap" =~ ^[0-9]+$ && "$overlap" -ge 0 && "$overlap" -le 3600 ]] || {
  echo "FAIL: HUBSPOT_SYNC_OVERLAP_SECONDS must be between 0 and 3600."
  exit 1
}

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
tmp_config="$(mktemp)"
n8n_stopped=false

cleanup() {
  rm -f "$tmp_config"
  if [[ "$n8n_stopped" == "true" ]]; then
    "${compose[@]}" up -d n8n >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

set_connector_state() {
  local state="$1"
  python3 - "$BASE_CONFIG" "$tmp_config" "$state" <<'PYCONFIG'
import json, sys
src, dst, state = sys.argv[1:4]
doc = json.load(open(src))
for connector in doc["connectors"]:
    if connector.get("connector_key") == "hubspot_primary":
        connector["active"] = state == "true"
json.dump(doc, open(dst, "w"), indent=2)
PYCONFIG
  CONNECTOR_CONFIG_FILE="$tmp_config" bash "$ROOT_DIR/scripts/apply-connector-config.sh"
}

n8n_cli() {
  "${compose[@]}" run --rm --no-deps -T n8n "$@"
}

import_publish() {
  local file="$1"
  local workflow_id="$2"
  cat "$file" | "${compose[@]}" run --rm --no-deps -T n8n \
    import:workflow --input=/dev/stdin
  n8n_cli publish:workflow --id="$workflow_id"
}

# Keep governance closed until credentials and workflows are ready.
bash "$ROOT_DIR/scripts/init-hubspot-connector.sh"
set_connector_state false

# n8n CLI mutation runs in isolated one-off containers while the long-running
# Agent v2 process is stopped. This avoids concurrent CLI/runtime crashes and
# gives the same deployment path for each client environment.
"${compose[@]}" stop n8n
n8n_stopped=true

bash "$ROOT_DIR/scripts/import-hubspot-runtime-credential.sh"
import_publish "$SYS_WORKFLOW" "REVINTV2SYSERROR01"
import_publish "$WORKFLOW" "REVINTV2HUBSPOT01"

"${compose[@]}" up -d n8n
n8n_stopped=false

port="${N8N_PORT:-5681}"
for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
    break
  fi
  [[ "$attempt" -ne 30 ]] || {
    echo "FAIL: Agent v2 n8n did not become healthy."
    exit 1
  }
  sleep 2
done

# Activate governance only after n8n is healthy and both workflows are published.
set_connector_state true
"${compose[@]}" exec -T reporting-db \
  psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" \
  -v lookback="$lookback" -v overlap="$overlap" <<'SQL'
UPDATE governance.reliability_policy
SET active=true, updated_at=now()
WHERE component_key='hubspot_sync';

INSERT INTO governance.circuit_state(component_key)
VALUES ('hubspot_sync')
ON CONFLICT (component_key) DO NOTHING;

INSERT INTO governance.connector_sync_state(
  connector_key, initial_lookback_days, overlap_seconds
)
VALUES (
  'hubspot_primary', :'lookback'::integer, :'overlap'::integer
)
ON CONFLICT (connector_key) DO UPDATE SET
  initial_lookback_days=EXCLUDED.initial_lookback_days,
  overlap_seconds=EXCLUDED.overlap_seconds,
  updated_at=now();
SQL

echo "PASS: HubSpot incremental sync activated with explicit confirmation."
echo "PASS: Agent v2 is healthy; protected old n8n was not modified."

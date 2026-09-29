#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AIRTABLE-01.json"
CONFIG="$ROOT_DIR/config/airtable-funnel-connector.example.json"
CONFIRM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    *) echo "FAIL: unknown argument $1"; exit 1 ;;
  esac
done

[[ "$CONFIRM" == "REVINT_AIRTABLE_FUNNEL" ]] || {
  echo "FAIL: explicit Airtable activation confirmation required."
  exit 1
}
[[ -f "$ENV_FILE" && -f "$WORKFLOW" && -f "$CONFIG" ]] || {
  echo "FAIL: required Airtable deployment file missing."; exit 1;
}

set -a
source "$ENV_FILE"
set +a

[[ "${AIRTABLE_SYNC_ENABLED:-false}" == "true" ]] || {
  echo "FAIL: AIRTABLE_SYNC_ENABLED must be true."; exit 1;
}

for name in AIRTABLE_PERSONAL_ACCESS_TOKEN AIRTABLE_BASE_ID AIRTABLE_TABLE_ID REPORTING_DB_ADMIN_USER REPORTING_DB_NAME N8N_DB_USER N8N_DB_NAME; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || { echo "FAIL: $name missing or placeholder."; exit 1; }
done

# Fail closed before changing runtime state if Airtable is unavailable or quota-limited.
whoami_status="$(curl -sS --max-time 15 -o /tmp/revint-airtable-whoami.json -w '%{http_code}'   -H "Authorization: Bearer $AIRTABLE_PERSONAL_ACCESS_TOKEN"   https://api.airtable.com/v0/meta/whoami || true)"
if [[ "$whoami_status" != "200" ]]; then
  rm -f /tmp/revint-airtable-whoami.json
  echo "FAIL: Airtable credential/API preflight returned HTTP $whoami_status."
  echo "No Agent V2 Airtable workflow or connector state was activated."
  exit 1
fi
rm -f /tmp/revint-airtable-whoami.json

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
bash "$ROOT_DIR/scripts/init-client-crm-connectors.sh"

tmp_config="$(mktemp)"
cleanup(){ rm -f "$tmp_config"; }
trap cleanup EXIT

python3 - "$CONFIG" "$tmp_config" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1]))
for c in doc["connectors"]:
    if c.get("connector_key")=="airtable_leads":
        c["active"]=True
json.dump(doc,open(sys.argv[2],"w"),indent=2)
PY

"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
    UPDATE governance.reliability_policy SET active=false,updated_at=now()
    WHERE component_key='airtable_sync';
  " >/dev/null

"${compose[@]}" stop n8n >/dev/null
restore(){ "${compose[@]}" up -d n8n >/dev/null 2>&1 || true; }
trap 'cleanup; restore' EXIT

bash "$ROOT_DIR/scripts/import-airtable-runtime-credential.sh"
cat "$WORKFLOW" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2AIRTABLE01 >/dev/null

"${compose[@]}" up -d n8n >/dev/null
for i in $(seq 1 40); do
  curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1 && break
  [[ "$i" -lt 40 ]] || { echo "FAIL: Agent V2 n8n did not recover."; exit 1; }
  sleep 2
done

CONNECTOR_CONFIG_FILE="$tmp_config" bash "$ROOT_DIR/scripts/apply-client-connector-config.sh"

lookback="${AIRTABLE_INITIAL_LOOKBACK_DAYS:-30}"
overlap="${AIRTABLE_SYNC_OVERLAP_SECONDS:-300}"
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -v lookback="$lookback" -v overlap="$overlap" <<'SQL'
UPDATE governance.reliability_policy
SET active=true,updated_at=now()
WHERE component_key='airtable_sync';

INSERT INTO governance.circuit_state(component_key)
VALUES ('airtable_sync')
ON CONFLICT (component_key) DO NOTHING;

INSERT INTO governance.connector_sync_state(connector_key,initial_lookback_days,overlap_seconds)
VALUES ('airtable_leads',:'lookback'::integer,:'overlap'::integer)
ON CONFLICT (connector_key) DO UPDATE SET
  initial_lookback_days=EXCLUDED.initial_lookback_days,
  overlap_seconds=EXCLUDED.overlap_seconds,
  updated_at=now();
SQL

trap cleanup EXIT
echo "PASS: Airtable lead/funnel adapter activated after API and health preflight."

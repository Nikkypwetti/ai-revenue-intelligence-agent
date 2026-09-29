#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SALESFORCE-01.json"
SYS_WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SYS-01.json"
BASE_CONFIG="$ROOT_DIR/config/salesforce-connector.example.json"
CONFIRMATION=""

fail(){ echo "FAIL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRMATION="${2:-}"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$CONFIRMATION" == "REVINT_SALESFORCE_CONNECTOR" ]] || fail "Salesforce activation confirmation token is missing or incorrect."
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ -f "$WORKFLOW" ]] || fail "Salesforce workflow template is missing."
[[ -f "$SYS_WORKFLOW" ]] || fail "reliability workflow template is missing."
[[ -f "$BASE_CONFIG" ]] || fail "Salesforce connector config is missing."

set -a
source "$ENV_FILE"
set +a

[[ "${SALESFORCE_SYNC_ENABLED:-false}" == "true" ]] || fail "SALESFORCE_SYNC_ENABLED must be true for activation."
[[ "${SALESFORCE_READONLY_CONFIRMED:-false}" == "true" ]] || fail "SALESFORCE_READONLY_CONFIRMED must be true after independently reviewing the Salesforce integration user/profile."

case "${SALESFORCE_INSTANCE_URL:-}" in
  https://*.my.salesforce.com|https://*.salesforce.com) ;;
  *) fail "SALESFORCE_INSTANCE_URL must be a non-placeholder HTTPS Salesforce host." ;;
esac
[[ "$SALESFORCE_INSTANCE_URL" != *CHANGE_ME* ]] || fail "SALESFORCE_INSTANCE_URL still uses a placeholder."

required=(REPORTING_DB_ADMIN_USER REPORTING_DB_NAME N8N_DB_USER N8N_DB_NAME)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || fail "$name is missing or uses a placeholder."
done

lookback="${SALESFORCE_INITIAL_LOOKBACK_DAYS:-30}"
overlap="${SALESFORCE_SYNC_OVERLAP_SECONDS:-300}"
[[ "$lookback" =~ ^[0-9]+$ && "$lookback" -ge 1 && "$lookback" -le 3650 ]] || fail "SALESFORCE_INITIAL_LOOKBACK_DAYS must be between 1 and 3650."
[[ "$overlap" =~ ^[0-9]+$ && "$overlap" -ge 0 && "$overlap" -le 3600 ]] || fail "SALESFORCE_SYNC_OVERLAP_SECONDS must be between 0 and 3600."

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
tmp_config="$(mktemp)"
tmp_workflow="$(mktemp)"
n8n_stopped=false

cleanup(){
  rm -f "$tmp_config" "$tmp_workflow"
  if [[ "$n8n_stopped" == "true" ]]; then
    "${compose[@]}" up -d n8n >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

credential_row="$("${compose[@]}" exec -T n8n-db psql -X -q -A -t -F '|' \
  -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
    SELECT id, count(*) OVER (), (data NOT LIKE '{%')::int
    FROM credentials_entity
    WHERE name='REVINT | Salesforce Opportunities RO'
      AND type='salesforceOAuth2Api';
  ")"
[[ -n "$credential_row" ]] || fail "dedicated Salesforce credential named REVINT | Salesforce Opportunities RO is missing."
IFS='|' read -r salesforce_credential_id salesforce_credential_count salesforce_encrypted <<< "$credential_row"
[[ "$salesforce_credential_count" == "1" && "$salesforce_encrypted" == "1" ]] || fail "Salesforce credential must exist exactly once and be stored encrypted."

python3 - "$WORKFLOW" "$tmp_workflow" "$salesforce_credential_id" <<'PY'
import json,sys
src,dst,credential_id=sys.argv[1:4]
doc=json.load(open(src))
found=False
for workflow in doc:
    for node in workflow.get("nodes",[]):
        if node.get("name")=="SRC | Fetch Salesforce Opportunities":
            node["credentials"]["salesforceOAuth2Api"]["id"]=credential_id
            node["credentials"]["salesforceOAuth2Api"]["name"]="REVINT | Salesforce Opportunities RO"
            found=True
if not found:
    raise SystemExit("FAIL: Salesforce source node not found.")
json.dump(doc,open(dst,"w"),indent=2)
PY

set_connector_state(){
  local state="$1"
  python3 - "$BASE_CONFIG" "$tmp_config" "$state" <<'PY'
import json,sys
src,dst,state=sys.argv[1:4]
doc=json.load(open(src))
for connector in doc["connectors"]:
    if connector.get("connector_key")=="salesforce_primary":
        connector["active"]=state=="true"
json.dump(doc,open(dst,"w"),indent=2)
PY
  CONNECTOR_CONFIG_FILE="$tmp_config" bash "$ROOT_DIR/scripts/apply-connector-config.sh"
}

n8n_cli(){ "${compose[@]}" run --rm --no-deps -T n8n "$@"; }
import_publish(){
  local file="$1" id="$2"
  cat "$file" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
  n8n_cli publish:workflow --id="$id" >/dev/null
}

bash "$ROOT_DIR/scripts/init-salesforce-connector.sh"
set_connector_state false

"${compose[@]}" stop n8n >/dev/null
n8n_stopped=true

import_publish "$SYS_WORKFLOW" "REVINTV2SYSERROR01"
import_publish "$tmp_workflow" "REVINTV2SALESFORCE01"

"${compose[@]}" up -d n8n >/dev/null
n8n_stopped=false

port="${N8N_PORT:-5681}"
for attempt in $(seq 1 40); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then break; fi
  [[ "$attempt" -lt 40 ]] || fail "Agent V2 n8n did not recover after Salesforce deployment."
  sleep 2
done

set_connector_state true
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME"   -v lookback="$lookback" -v overlap="$overlap" <<'SQL'
UPDATE governance.reliability_policy
SET active=true, updated_at=now()
WHERE component_key='salesforce_sync';

INSERT INTO governance.circuit_state(component_key)
VALUES ('salesforce_sync')
ON CONFLICT (component_key) DO NOTHING;

INSERT INTO governance.connector_sync_state(
  connector_key, initial_lookback_days, overlap_seconds
)
VALUES (
  'salesforce_primary', :'lookback'::integer, :'overlap'::integer
)
ON CONFLICT (connector_key) DO UPDATE SET
  initial_lookback_days=EXCLUDED.initial_lookback_days,
  overlap_seconds=EXCLUDED.overlap_seconds,
  updated_at=now();
SQL

echo "PASS: Salesforce Opportunity sync activated with explicit read-only confirmation."
echo "PASS: Agent V2 health recovered; no legacy n8n deployment was targeted."

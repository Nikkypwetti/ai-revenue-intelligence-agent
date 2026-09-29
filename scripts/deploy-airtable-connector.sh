#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AIRTABLE-01.json"
SYS_WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SYS-01.json"
CONFIG="${AIRTABLE_CONNECTOR_CONFIG_FILE:-$ROOT_DIR/config/connectors.local.json}"
CONFIRM=""

fail(){ echo "FAIL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$CONFIRM" == "REVINT_AIRTABLE_CONNECTOR" ]] || fail "Airtable activation confirmation token is missing or incorrect."
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ -f "$WORKFLOW" ]] || fail "Airtable workflow template is missing."
[[ -f "$SYS_WORKFLOW" ]] || fail "reliability workflow template is missing."
[[ -f "$CONFIG" ]] || fail "Airtable local connector config is missing."

set -a
source "$ENV_FILE"
set +a

[[ "${AIRTABLE_SYNC_ENABLED:-false}" == "true" ]] || fail "AIRTABLE_SYNC_ENABLED must be true for activation."

required=(
  AIRTABLE_PERSONAL_ACCESS_TOKEN AIRTABLE_BASE_ID AIRTABLE_TABLE_ID AIRTABLE_LAST_MODIFIED_FIELD
  REPORTING_DB_ADMIN_USER REPORTING_DB_NAME N8N_DB_USER N8N_DB_NAME
)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || fail "$name is missing or placeholder."
done

[[ "$AIRTABLE_BASE_ID" =~ ^app[A-Za-z0-9]+$ ]] || fail "AIRTABLE_BASE_ID must be an Airtable base ID."
[[ "$AIRTABLE_TABLE_ID" =~ ^tbl[A-Za-z0-9]+$ ]] || fail "AIRTABLE_TABLE_ID must be an Airtable table ID."
field_re='^[A-Za-z0-9_ -]{1,100}$'
[[ "$AIRTABLE_LAST_MODIFIED_FIELD" =~ $field_re ]] || fail "AIRTABLE_LAST_MODIFIED_FIELD contains unsupported characters."

lookback="${AIRTABLE_INITIAL_LOOKBACK_DAYS:-30}"
overlap="${AIRTABLE_SYNC_OVERLAP_SECONDS:-300}"
[[ "$lookback" =~ ^[0-9]+$ && "$lookback" -ge 1 && "$lookback" -le 3650 ]] || fail "AIRTABLE_INITIAL_LOOKBACK_DAYS must be between 1 and 3650."
[[ "$overlap" =~ ^[0-9]+$ && "$overlap" -ge 0 && "$overlap" -le 3600 ]] || fail "AIRTABLE_SYNC_OVERLAP_SECONDS must be between 0 and 3600."

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
tmp="$(mktemp)"
n8n_stopped=false

cleanup(){
  rm -f "$tmp"
  if [[ "$n8n_stopped" == "true" ]]; then
    "${compose[@]}" up -d n8n >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

bash "$ROOT_DIR/scripts/init-airtable-connector.sh"
bash "$ROOT_DIR/scripts/import-airtable-runtime-credential.sh"

credential_state="$("${compose[@]}" exec -T n8n-db psql -X -q -A -t   -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
  SELECT count(*) || '|' || count(*) FILTER (WHERE data NOT LIKE '{%')
  FROM credentials_entity
  WHERE id='REVINTAIRTABLE001' AND type='airtableTokenApi';
")"
[[ "$credential_state" == "1|1" ]] || fail "dedicated encrypted Airtable credential REVINTAIRTABLE001 is missing."

set_state(){
  local state="$1"
  python3 - "$CONFIG" "$tmp" "$state" <<'PY'
import json,sys
src,dst,state=sys.argv[1:4]
doc=json.load(open(src))
for c in doc["connectors"]:
    if c.get("connector_key")=="airtable_primary":
        c["active"]=state=="true"
json.dump(doc,open(dst,"w"),indent=2)
PY
  CONNECTOR_CONFIG_FILE="$tmp" bash "$ROOT_DIR/scripts/apply-connector-config.sh"
}

set_state false
"${compose[@]}" stop n8n >/dev/null
n8n_stopped=true

cat "$SYS_WORKFLOW" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2SYSERROR01 >/dev/null
cat "$WORKFLOW" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2AIRTABLE01 >/dev/null

"${compose[@]}" up -d n8n >/dev/null
n8n_stopped=false

for i in $(seq 1 40); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1; then
    break
  fi
  [[ "$i" -lt 40 ]] || fail "Agent V2 n8n did not recover after Airtable deployment."
  sleep 2
done

set_state true
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME"   -v lookback="$lookback" -v overlap="$overlap" <<'SQL'
UPDATE governance.reliability_policy
SET active=true, updated_at=now()
WHERE component_key='airtable_sync';

INSERT INTO governance.circuit_state(component_key)
VALUES ('airtable_sync')
ON CONFLICT (component_key) DO NOTHING;

INSERT INTO governance.connector_sync_state(
  connector_key, initial_lookback_days, overlap_seconds
)
VALUES (
  'airtable_primary', :'lookback'::integer, :'overlap'::integer
)
ON CONFLICT (connector_key) DO UPDATE SET
  initial_lookback_days=EXCLUDED.initial_lookback_days,
  overlap_seconds=EXCLUDED.overlap_seconds,
  updated_at=now();
SQL

echo "PASS: Airtable Opportunity sync activated with verified local field mappings."

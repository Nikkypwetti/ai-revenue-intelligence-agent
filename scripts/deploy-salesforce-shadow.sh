#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SALESFORCE-01.json"
CONFIG="$ROOT_DIR/config/salesforce-connector.example.json"
CONFIRM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    *) echo "FAIL: unknown argument $1"; exit 1 ;;
  esac
done

[[ "$CONFIRM" == "REVINT_SALESFORCE_SHADOW" ]] || {
  echo "FAIL: explicit shadow activation confirmation required."
  exit 1
}
[[ -f "$ENV_FILE" && -f "$WORKFLOW" && -f "$CONFIG" ]] || {
  echo "FAIL: required Salesforce deployment file missing."; exit 1;
}

set -a
source "$ENV_FILE"
set +a

[[ "${SALESFORCE_SYNC_ENABLED:-false}" == "true" ]] || {
  echo "FAIL: SALESFORCE_SYNC_ENABLED must be true."; exit 1;
}
[[ "${SALESFORCE_CANONICAL_WRITE_ENABLED:-false}" == "false" ]] || {
  echo "FAIL: shadow activation requires SALESFORCE_CANONICAL_WRITE_ENABLED=false."
  echo "FAIL: do not enable canonical Salesforce writes while HubSpot is authoritative."
  exit 1
}

for name in REPORTING_DB_ADMIN_USER REPORTING_DB_NAME N8N_DB_USER N8N_DB_NAME; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || { echo "FAIL: $name missing."; exit 1; }
done

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

credential_row="$("${compose[@]}" exec -T n8n-db psql -X -q -A -F '|' \
  -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
    SELECT id,name,type
    FROM credentials_entity
    WHERE name='REVINT | Salesforce Opportunities RO'
      AND type='salesforceOAuth2Api'
    ORDER BY \"createdAt\" DESC
    LIMIT 1;
  ")"

IFS='|' read -r sf_credential_id sf_credential_name sf_credential_type <<<"$credential_row"
[[ -n "$sf_credential_id" && "$sf_credential_type" == "salesforceOAuth2Api" ]] || {
  echo "FAIL: dedicated Salesforce OAuth2 credential is not present in Agent V2."
  echo "Create it in the Agent V2 n8n UI with exact name: REVINT | Salesforce Opportunities RO"
  exit 1
}

bash "$ROOT_DIR/scripts/init-client-crm-connectors.sh"

tmp_config="$(mktemp)"
tmp_workflow="$(mktemp)"
cleanup(){ rm -f "$tmp_config" "$tmp_workflow"; }
trap cleanup EXIT

python3 - "$CONFIG" "$tmp_config" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1]))
for c in doc["connectors"]:
    if c.get("connector_key")=="salesforce_primary":
        c["active"]=True
json.dump(doc,open(sys.argv[2],"w"),indent=2)
PY

python3 - "$WORKFLOW" "$tmp_workflow" "$sf_credential_id" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1]))
for n in doc[0]["nodes"]:
    if n.get("name")=="SRC | Query Salesforce Opportunities":
        n["credentials"]["salesforceOAuth2Api"]["id"]=sys.argv[3]
json.dump(doc,open(sys.argv[2],"w"),indent=2)
PY

"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1 \
  -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
    UPDATE governance.reliability_policy SET active=false,updated_at=now()
    WHERE component_key='salesforce_sync';
  " >/dev/null

"${compose[@]}" stop n8n >/dev/null
restore(){ "${compose[@]}" up -d n8n >/dev/null 2>&1 || true; }
trap 'cleanup; restore' EXIT

cat "$tmp_workflow" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2SALESFORCE01 >/dev/null

"${compose[@]}" up -d n8n >/dev/null
for i in $(seq 1 40); do
  curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1 && break
  [[ "$i" -lt 40 ]] || { echo "FAIL: Agent V2 n8n did not recover."; exit 1; }
  sleep 2
done

CONNECTOR_CONFIG_FILE="$tmp_config" bash "$ROOT_DIR/scripts/apply-client-connector-config.sh"

lookback="${SALESFORCE_INITIAL_LOOKBACK_DAYS:-30}"
overlap="${SALESFORCE_SYNC_OVERLAP_SECONDS:-300}"
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1 \
  -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -v lookback="$lookback" -v overlap="$overlap" <<'SQL'
UPDATE governance.reliability_policy
SET active=true,updated_at=now()
WHERE component_key='salesforce_sync';

INSERT INTO governance.circuit_state(component_key)
VALUES ('salesforce_sync')
ON CONFLICT (component_key) DO NOTHING;

INSERT INTO governance.connector_sync_state(connector_key,initial_lookback_days,overlap_seconds)
VALUES ('salesforce_primary',:'lookback'::integer,:'overlap'::integer)
ON CONFLICT (connector_key) DO UPDATE SET
  initial_lookback_days=EXCLUDED.initial_lookback_days,
  overlap_seconds=EXCLUDED.overlap_seconds,
  updated_at=now();
SQL

trap cleanup EXIT
echo "PASS: Salesforce adapter activated in shadow-validation mode."
echo "PASS: canonical Salesforce deal writes remain disabled."

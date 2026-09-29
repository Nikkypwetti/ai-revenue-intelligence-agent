#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
STATIC_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static-only) STATIC_ONLY=1; shift ;;
    *) echo "FAIL: unknown argument: $1"; exit 1 ;;
  esac
done

python3 -m json.tool "$ROOT_DIR/config/salesforce-connector.example.json" >/dev/null
python3 -m json.tool "$ROOT_DIR/config/airtable-funnel-connector.example.json" >/dev/null
python3 -m json.tool "$ROOT_DIR/clients/nikkytechies/client-config.example.json" >/dev/null
python3 -m json.tool "$ROOT_DIR/clients/nikkytechies/hubspot-stage-map.json" >/dev/null

CONNECTOR_CONFIG_FILE="$ROOT_DIR/config/salesforce-connector.example.json" \
  bash "$ROOT_DIR/scripts/apply-client-connector-config.sh" --validate-only
CONNECTOR_CONFIG_FILE="$ROOT_DIR/config/airtable-funnel-connector.example.json" \
  bash "$ROOT_DIR/scripts/apply-client-connector-config.sh" --validate-only

grep -q "SECURITY DEFINER" "$ROOT_DIR/database/migrations/030_client_crm_connectors.sql"
grep -q "TO revint_connector_ingest" "$ROOT_DIR/database/migrations/030_client_crm_connectors.sql"
grep -q "TO revint_governance_ro" "$ROOT_DIR/database/migrations/030_client_crm_connectors.sql"
grep -q "TO revint_audit_insert" "$ROOT_DIR/database/migrations/030_client_crm_connectors.sql"
grep -q '"mode": "shadow"' "$ROOT_DIR/clients/nikkytechies/client-config.example.json"
grep -q '"enabled": false' "$ROOT_DIR/config/salesforce-connector.example.json"
grep -q '"active": false' "$ROOT_DIR/config/airtable-funnel-connector.example.json"

if [[ "$STATIC_ONLY" -eq 1 ]]; then
  echo "PASS: static client CRM connector verification passed."
  exit 0
fi

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$ROOT_DIR/deploy/docker-compose.yml")

state="$("${compose[@]}" exec -T reporting-db psql -X -q -A -t \
  -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
    SELECT
      has_function_privilege('$CONNECTOR_DB_WRITER_USER','ingestion.ingest_funnel_from_source(text,text,jsonb)','EXECUTE')::int
      || '|' ||
      has_table_privilege('$CONNECTOR_DB_WRITER_USER','reporting.funnel_records','INSERT')::int
      || '|' ||
      has_table_privilege('$CONNECTOR_DB_WRITER_USER','reporting.funnel_records','SELECT')::int;
  ")"

[[ "$state" == "1|0|0" ]] || {
  echo "FAIL: funnel connector least-privilege boundary is incorrect: $state"
  exit 1
}

echo "PASS: client CRM connector least-privilege verification passed."

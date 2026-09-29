#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
CONFIRM="${1:-}"

[[ "$CONFIRM" == "REVINT_STAGE_CLIENT_ADAPTERS" ]] || {
  echo "FAIL: pass REVINT_STAGE_CLIENT_ADAPTERS to stage disabled adapters."
  exit 1
}

set -a
source "$ENV_FILE"
set +a
compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

bash "$ROOT_DIR/scripts/init-client-source-adapters.sh"

"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
UPDATE governance.connector_registry
SET active=false,updated_at=now()
WHERE connector_key IN ('salesforce_primary','airtable_primary');
UPDATE governance.connector_runtime_config
SET read_enabled=false,write_enabled=false,updated_at=now()
WHERE connector_key IN ('salesforce_primary','airtable_primary');
UPDATE governance.reliability_policy
SET active=false,updated_at=now()
WHERE component_key IN ('salesforce_sync','airtable_sync');" >/dev/null

cleanup() {
  "${compose[@]}" up -d n8n >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${compose[@]}" stop n8n >/dev/null

for pair in   "REVINT-V2-SALESFORCE-01.json:REVINTV2SALESFORCE01"   "REVINT-V2-AIRTABLE-01.json:REVINTV2AIRTABLE01"   "REVINT-V2-SYS-01.json:REVINTV2SYSERROR01"
do
  file="${pair%%:*}"
  id="${pair##*:}"
  cat "$ROOT_DIR/workflows/runtime-templates/$file" |
    "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
  "${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id="$id" >/dev/null
done

"${compose[@]}" up -d n8n >/dev/null
for attempt in $(seq 1 40); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1; then
    break
  fi
  [[ "$attempt" -lt 40 ]] || { echo "FAIL: Agent V2 n8n did not recover."; exit 1; }
  sleep 2
done

trap - EXIT
echo "PASS: Salesforce/Airtable workflows published with connector governance disabled."


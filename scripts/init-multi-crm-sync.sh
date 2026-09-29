#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
MIGRATION="$ROOT_DIR/database/migrations/016_multi_crm_connector_sync.sql"
SEED="$ROOT_DIR/database/seeds/009_multi_crm_reliability.sql"

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ -f "$MIGRATION" ]] || fail "multi-CRM connector migration is missing."
[[ -f "$SEED" ]] || fail "multi-CRM reliability seed is missing."

set -a
source "$ENV_FILE"
set +a

: "${REPORTING_DB_ADMIN_USER:?Missing REPORTING_DB_ADMIN_USER}"
: "${REPORTING_DB_NAME:?Missing REPORTING_DB_NAME}"

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

cat "$MIGRATION" | "${compose[@]}" exec -T reporting-db   psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" >/dev/null

cat "$SEED" | "${compose[@]}" exec -T reporting-db   psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" >/dev/null

echo "PASS: reusable HubSpot/Salesforce/Airtable sync governance initialized."
echo "PASS: Salesforce and Airtable reliability policies remain disabled until explicit client activation."

#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
set -a
source "$ENV_FILE"
set +a

: "${REPORTING_DB_ADMIN_USER:?Missing REPORTING_DB_ADMIN_USER}"
: "${REPORTING_DB_NAME:?Missing REPORTING_DB_NAME}"

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

cat "$ROOT_DIR/database/migrations/017_client_source_adapters.sql" |
  "${compose[@]}" exec -T reporting-db     psql -X -v ON_ERROR_STOP=1     -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" >/dev/null

echo "PASS: Salesforce/Airtable client-source governance initialized safe-disabled."


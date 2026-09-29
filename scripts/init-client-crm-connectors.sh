#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
MIGRATION="$ROOT_DIR/database/migrations/016_client_crm_connectors.sql"
SEED="$ROOT_DIR/database/seeds/011_client_crm_reliability.sql"
SALESFORCE_CONFIG="${SALESFORCE_CONNECTOR_CONFIG_FILE:-$ROOT_DIR/config/salesforce-connector.example.json}"
AIRTABLE_CONFIG="${AIRTABLE_CONNECTOR_CONFIG_FILE:-$ROOT_DIR/config/airtable-funnel-connector.example.json}"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for name in REPORTING_DB_ADMIN_USER REPORTING_DB_NAME; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || {
    echo "FAIL: $name is missing or placeholder."
    exit 1
  }
done

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
  psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" < "$MIGRATION"

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
  psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" < "$SEED"

CONNECTOR_CONFIG_FILE="$SALESFORCE_CONFIG" bash "$ROOT_DIR/scripts/apply-client-connector-config.sh"
CONNECTOR_CONFIG_FILE="$AIRTABLE_CONFIG" bash "$ROOT_DIR/scripts/apply-client-connector-config.sh"

echo "PASS: client CRM connector contracts initialized safe-disabled."

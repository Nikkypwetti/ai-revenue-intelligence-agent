#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
MIGRATION="$ROOT_DIR/database/migrations/010_hubspot_connector.sql"
SEED="$ROOT_DIR/database/seeds/008_hubspot_reliability.sql"
CONNECTOR_CONFIG="${CONNECTOR_CONFIG_FILE:-$ROOT_DIR/config/hubspot-connector.example.json}"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
[[ -f "$MIGRATION" ]] || { echo "FAIL: HubSpot connector migration is missing."; exit 1; }
[[ -f "$SEED" ]] || { echo "FAIL: HubSpot reliability seed is missing."; exit 1; }
[[ -f "$CONNECTOR_CONFIG" ]] || { echo "FAIL: HubSpot connector config is missing."; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for name in REPORTING_DB_ADMIN_USER REPORTING_DB_NAME; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || {
    echo "FAIL: $name is missing or uses a placeholder."
    exit 1
  }
done

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
  psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" < "$MIGRATION"

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
  psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" < "$SEED"

CONNECTOR_CONFIG_FILE="$CONNECTOR_CONFIG" \
  bash "$ROOT_DIR/scripts/apply-connector-config.sh"

echo "PASS: HubSpot connector schema, disabled policy, and inactive mapping initialized."

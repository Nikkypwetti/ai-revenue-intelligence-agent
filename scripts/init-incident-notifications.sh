#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
source "$ENV_FILE"
set +a

for name in REPORTING_DB_ADMIN_USER REPORTING_DB_NAME; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || { echo "FAIL: $name missing."; exit 1; }
done

docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
  psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" \
  < "$ROOT_DIR/database/migrations/017_incident_notifications.sql"

docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
  psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" \
  < "$ROOT_DIR/database/seeds/012_incident_notification_reliability.sql"

echo "PASS: incident notification governance initialized safe-disabled."

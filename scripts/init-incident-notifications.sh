#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
MIGRATION="$ROOT_DIR/database/migrations/017_incident_notifications.sql"
SEED="$ROOT_DIR/database/seeds/010_incident_notification_reliability.sql"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }

set -a
source "$ENV_FILE"
set +a
: "${REPORTING_DB_ADMIN_USER:?Missing REPORTING_DB_ADMIN_USER}"
: "${REPORTING_DB_NAME:?Missing REPORTING_DB_NAME}"

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

cat "$MIGRATION" | "${compose[@]}" exec -T reporting-db   psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" >/dev/null
cat "$SEED" | "${compose[@]}" exec -T reporting-db   psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" >/dev/null

"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
    UPDATE governance.incident_notification_config
    SET enabled=false, updated_at=now()
    WHERE config_id=1;
  " >/dev/null

echo "PASS: incident notification governance initialized safe-disabled."

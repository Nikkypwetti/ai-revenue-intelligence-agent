#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
set -a; source "$ENV_FILE"; set +a
compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
cat "$ROOT_DIR/database/migrations/018_email_delivery.sql" | "${compose[@]}" exec -T reporting-db psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" >/dev/null
cat "$ROOT_DIR/database/seeds/012_email_delivery_reliability.sql" | "${compose[@]}" exec -T reporting-db psql -X -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" >/dev/null
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "UPDATE governance.email_delivery_config SET email_report_enabled=false, updated_at=now() WHERE config_id=1;" >/dev/null
echo "PASS: governed email delivery initialized safe-disabled with reliability policy."

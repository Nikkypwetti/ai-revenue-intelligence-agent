#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

MIGRATIONS=(
  "$ROOT_DIR/database/migrations/011_revenue_question_pack.sql"
  "$ROOT_DIR/database/migrations/012_revenue_question_pack_engine.sql"
  "$ROOT_DIR/database/migrations/013_revenue_question_pack_ingestion.sql"
)
SEED="$ROOT_DIR/database/seeds/009_revenue_question_pack.sql"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(REPORTING_DB_ADMIN_USER REPORTING_DB_NAME)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

TARGET_DB="${REVENUE_PACK_DB_NAME:-$REPORTING_DB_NAME}"

psql_admin() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
    psql -X -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_ADMIN_USER" -d "$TARGET_DB" "$@"
}

for migration in "${MIGRATIONS[@]}"; do
  psql_admin < "$migration"
done
psql_admin < "$SEED"

echo "PASS: reusable Agent V2 Revenue Question Pack initialized in $TARGET_DB."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
MIGRATION="$ROOT_DIR/database/migrations/014_reusable_security_gateway.sql"
SEED="$ROOT_DIR/database/seeds/010_reusable_security_gateway.sql"

[[ -f "$ENV_FILE" ]] || {
  echo "FAIL: $ENV_FILE does not exist."
  exit 1
}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(REPORTING_DB_ADMIN_USER REPORTING_DB_NAME)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or uses a placeholder."
    exit 1
  fi
done

TARGET_DB="${SECURITY_GATEWAY_DB_NAME:-$REPORTING_DB_NAME}"

compose=(
  docker compose
  -p "${COMPOSE_PROJECT_NAME:-revint-agent}"
  --env-file "$ENV_FILE"
  -f "$COMPOSE_FILE"
)

"${compose[@]}" exec -T reporting-db   psql -X -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER"   -d "$TARGET_DB" < "$MIGRATION"

"${compose[@]}" exec -T reporting-db   psql -X -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER"   -d "$TARGET_DB" < "$SEED"

echo "PASS: reusable Agent V2 security gateway initialized."

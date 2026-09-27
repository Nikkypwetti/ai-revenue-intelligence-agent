#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
MIGRATION="$ROOT_DIR/database/migrations/007_reliability_core.sql"
SEED="$ROOT_DIR/database/seeds/006_reliability_policies.sql"

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

psql_admin() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db     psql -X -v ON_ERROR_STOP=1     -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" "$@"
}

psql_admin < "$MIGRATION"
psql_admin < "$SEED"

echo "PASS: reliability policies, circuit state, terminal-failure logging, and dead-letter controls initialized."

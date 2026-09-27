#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
MIGRATION="$ROOT_DIR/database/migrations/002_stage3_connector_contract.sql"
QUERY_SEED="$ROOT_DIR/database/seeds/002_query_templates.sql"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL: $ENV_FILE does not exist."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  REPORTING_DB_ADMIN_USER REPORTING_DB_NAME
  CONNECTOR_DB_WRITER_USER CONNECTOR_DB_WRITER_PASSWORD
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

[[ "$CONNECTOR_DB_WRITER_USER" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
  echo "FAIL: invalid PostgreSQL role name: $CONNECTOR_DB_WRITER_USER"
  exit 1
}

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
  psql -X -v ON_ERROR_STOP=1 \
  -U "$REPORTING_DB_ADMIN_USER" \
  -d "$REPORTING_DB_NAME" \
  -v connector_writer_user="$CONNECTOR_DB_WRITER_USER" \
  -v connector_writer_password="$CONNECTOR_DB_WRITER_PASSWORD" \
  < "$MIGRATION"

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
  psql -X -v ON_ERROR_STOP=1 \
  -U "$REPORTING_DB_ADMIN_USER" \
  -d "$REPORTING_DB_NAME" \
  < "$QUERY_SEED"

echo "PASS: Stage 3 connector/data-contract schema and approved query templates initialized."

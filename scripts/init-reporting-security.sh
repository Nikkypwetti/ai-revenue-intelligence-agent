#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
MIGRATION="$ROOT_DIR/database/migrations/001_stage2_security.sql"

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
  REPORTING_DB_READER_USER REPORTING_DB_READER_PASSWORD
  AUDIT_DB_WRITER_USER AUDIT_DB_WRITER_PASSWORD
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db   psql -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER"   -d "$REPORTING_DB_NAME"   -v reader_user="$REPORTING_DB_READER_USER"   -v reader_password="$REPORTING_DB_READER_PASSWORD"   -v audit_user="$AUDIT_DB_WRITER_USER"   -v audit_password="$AUDIT_DB_WRITER_PASSWORD"   < "$MIGRATION"

echo "PASS: Stage 2 reporting schemas and least-privilege roles initialized."

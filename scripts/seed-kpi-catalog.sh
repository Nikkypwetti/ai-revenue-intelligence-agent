#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
SEED="$ROOT_DIR/database/seeds/001_kpi_catalog.sql"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db   psql -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER"   -d "$REPORTING_DB_NAME"   < "$SEED"

echo "PASS: Governed KPI catalogue seeded."

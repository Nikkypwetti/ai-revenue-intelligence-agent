#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

TENANT_KEY=""
DISPLAY_NAME=""

usage() {
  echo "Usage: bash scripts/configure-security-tenant.sh --tenant-key <key> --display-name <name>"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-key) TENANT_KEY="${2:-}"; shift 2 ;;
    --display-name) DISPLAY_NAME="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$TENANT_KEY" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || {
  echo "FAIL: invalid tenant key."
  exit 1
}

[[ -n "$DISPLAY_NAME" && "${#DISPLAY_NAME}" -le 200 ]] || {
  echo "FAIL: display name is required and must be <=200 chars."
  exit 1
}
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

TARGET_DB="${SECURITY_GATEWAY_DB_NAME:-$REPORTING_DB_NAME}"

compose=(
  docker compose
  -p "${COMPOSE_PROJECT_NAME:-revint-agent}"
  --env-file "$ENV_FILE"
  -f "$COMPOSE_FILE"
)

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

tenant_sql="$(sql_escape "$TENANT_KEY")"
name_sql="$(sql_escape "$DISPLAY_NAME")"

"${compose[@]}" exec -T reporting-db   psql -X -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER"   -d "$TARGET_DB" <<SQL
BEGIN;
INSERT INTO governance.tenant_registry(tenant_key,display_name,active)
VALUES ('$tenant_sql','$name_sql',true)
ON CONFLICT (tenant_key) DO UPDATE SET
  display_name=EXCLUDED.display_name,
  active=true,
  updated_at=now();
UPDATE governance.principal_registry
SET tenant_key='$tenant_sql',
    updated_at=now()
WHERE tenant_key=(
  SELECT tenant_key
  FROM governance.deployment_security_config
  WHERE config_id=1
);

UPDATE governance.deployment_security_config
SET tenant_key='$tenant_sql',
    deployment_mode='isolated',
    updated_at=now()
WHERE config_id=1;

UPDATE governance.service_identity_registry
SET tenant_key='$tenant_sql',
    updated_at=now();

COMMIT;
SQL

echo "PASS: Agent V2 deployment tenant configured as $TENANT_KEY."
echo "MODE=isolated"

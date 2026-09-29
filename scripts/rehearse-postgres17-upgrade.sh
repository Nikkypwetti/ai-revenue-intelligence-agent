#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT_DIR/backups}"
BACKUP_PATH=""
CONFIRM=""

fail() { echo "FAIL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) BACKUP_PATH="${2:-}"; shift 2 ;;
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage:
  bash scripts/rehearse-postgres17-upgrade.sh \
    [--backup backups/<timestamp>] \
    --confirm REVINT_PG17_REHEARSAL

This is a non-destructive PostgreSQL 17 rehearsal. It never changes deploy/.env,
never touches the live Agent V2 database volumes, and restores the selected
backup only into temporary PostgreSQL 17 containers.
EOF
      exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$CONFIRM" == "REVINT_PG17_REHEARSAL" ]] || fail "confirmation token is missing."
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."

set -a
source "$ENV_FILE"
set +a

if [[ -z "$BACKUP_PATH" ]]; then
  latest="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20??????T??????Z' -printf '%f\n' 2>/dev/null | sort | tail -1)"
  [[ -n "$latest" ]] || fail "no completed backup exists under $BACKUP_ROOT."
  BACKUP_PATH="$BACKUP_ROOT/$latest"
fi
BACKUP_PATH="$(readlink -f "$BACKUP_PATH")"
[[ -d "$BACKUP_PATH" ]] || fail "backup does not exist: $BACKUP_PATH"

bash "$ROOT_DIR/scripts/verify-backup-recovery.sh" "$BACKUP_PATH"

manifest_value() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$BACKUP_PATH/manifest.env"
}

n8n_dump="$(manifest_value N8N_DB_DUMP)"
reporting_dump="$(manifest_value REPORTING_DB_DUMP)"
[[ -f "$BACKUP_PATH/$n8n_dump" && -f "$BACKUP_PATH/$reporting_dump" ]] || fail "backup dumps are missing."

command -v docker >/dev/null || fail "docker is unavailable."

image="${PG17_REHEARSAL_IMAGE:-postgres:17-alpine}"
suffix="$$"
n8n_name="revint-pg17-n8n-rehearsal-$suffix"
reporting_name="revint-pg17-reporting-rehearsal-$suffix"
password="revint-rehearsal-only"

cleanup() {
  docker rm -f "$n8n_name" "$reporting_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker pull "$image" >/dev/null

start_pg() {
  local name="$1"
  docker run -d --rm --name "$name" \
    -e POSTGRES_PASSWORD="$password" \
    "$image" >/dev/null
  for _ in $(seq 1 40); do
    if docker exec "$name" pg_isready -U postgres >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail "$name did not become ready."
}

start_pg "$n8n_name"
start_pg "$reporting_name"

docker exec "$n8n_name" createdb -U postgres revint_n8n_rehearsal
docker exec "$reporting_name" createdb -U postgres revint_reporting_rehearsal

docker exec -i "$n8n_name" pg_restore -U postgres -d revint_n8n_rehearsal --no-owner --no-privileges < "$BACKUP_PATH/$n8n_dump"
docker exec -i "$reporting_name" pg_restore -U postgres -d revint_reporting_rehearsal --no-owner --no-privileges < "$BACKUP_PATH/$reporting_dump"

workflow_table="$(docker exec "$n8n_name" psql -U postgres -d revint_n8n_rehearsal -At -c "SELECT to_regclass('public.workflow_entity') IS NOT NULL;")"
governance_schema="$(docker exec "$reporting_name" psql -U postgres -d revint_reporting_rehearsal -At -c "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name='governance');")"
reporting_schema="$(docker exec "$reporting_name" psql -U postgres -d revint_reporting_rehearsal -At -c "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name='reporting');")"
audit_schema="$(docker exec "$reporting_name" psql -U postgres -d revint_reporting_rehearsal -At -c "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name='audit');")"
pg_version="$(docker exec "$reporting_name" psql -U postgres -At -c "SHOW server_version;")"

[[ "$workflow_table" == "t" ]] || fail "restored n8n database is missing workflow_entity."
[[ "$governance_schema" == "t" && "$reporting_schema" == "t" && "$audit_schema" == "t" ]] || fail "restored reporting database is missing required schemas."

echo "PASS: PostgreSQL 17 rehearsal restored both Agent V2 databases into isolated temporary containers."
echo "PASS: required n8n/reporting/governance/audit structures are present."
echo "POSTGRES17_REHEARSAL_VERSION=$pg_version"
echo "LIVE_DEPLOYMENT_CHANGED=false"

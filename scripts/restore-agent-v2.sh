#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT_DIR/backups}"

BACKUP_PATH=""
CONFIRM=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/restore-agent-v2.sh --backup /path/to/backup     --confirm REVINT_AGENT_V2_LIVE_RESTORE

This restores the complete Agent v2 local deployment:
- n8n PostgreSQL database
- reporting PostgreSQL database
- n8n persistent data volume

A fresh pre-restore backup is always created first.
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      BACKUP_PATH="${2:-}"
      shift 2
      ;;
    --confirm)
      CONFIRM="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$CONFIRM" == "REVINT_AGENT_V2_LIVE_RESTORE" ]] || {
  usage
  fail "live restore confirmation token is missing."
}

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "$BACKUP_PATH" ]]; then
  latest="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d     -name '20??????T??????Z' -printf '%f
' 2>/dev/null | sort | tail -1)"
  [[ -n "$latest" ]] || fail "no completed backup exists under $BACKUP_ROOT."
  BACKUP_PATH="$BACKUP_ROOT/$latest"
fi

BACKUP_PATH="$(readlink -f "$BACKUP_PATH")"
[[ -d "$BACKUP_PATH" ]] || fail "backup directory does not exist."
[[ -f "$BACKUP_PATH/manifest.env" && -f "$BACKUP_PATH/SHA256SUMS" ]] ||   fail "backup manifest/checksums are incomplete."

bash "$ROOT_DIR/scripts/verify-backup-recovery.sh" "$BACKUP_PATH"

manifest_value() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$BACKUP_PATH/manifest.env"
}

manifest_n8n_db="$(manifest_value N8N_DB_NAME)"
manifest_reporting_db="$(manifest_value REPORTING_DB_NAME)"
n8n_dump="$(manifest_value N8N_DB_DUMP)"
reporting_dump="$(manifest_value REPORTING_DB_DUMP)"
n8n_archive="$(manifest_value N8N_DATA_ARCHIVE)"

[[ "$manifest_n8n_db" == "$N8N_DB_NAME" ]] ||   fail "backup n8n database name does not match the current deployment."
[[ "$manifest_reporting_db" == "$REPORTING_DB_NAME" ]] ||   fail "backup reporting database name does not match the current deployment."

echo "Creating mandatory pre-restore backup..."
pre_restore_output="$(BACKUP_ROOT="$BACKUP_ROOT" bash "$ROOT_DIR/scripts/backup-agent-v2.sh")"
pre_restore_path="$(awk -F= '$1=="BACKUP_PATH" {print $2}' <<<"$pre_restore_output" | tail -1)"
[[ -d "$pre_restore_path" ]] || fail "pre-restore backup was not created."
echo "PRE_RESTORE_BACKUP=$pre_restore_path"

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

restore_failed=1
restore_cleanup() {
  if [[ "$restore_failed" -ne 0 ]]; then
    echo "WARNING: restore did not complete successfully." >&2
    echo "Agent v2 n8n is intentionally left stopped to avoid running against a partial restore." >&2
    echo "PRE_RESTORE_BACKUP=$pre_restore_path" >&2
  fi
}
trap restore_cleanup EXIT

echo "Stopping Agent v2 n8n application container..."
"${compose[@]}" stop n8n

echo "Restoring n8n PostgreSQL database..."
"${compose[@]}" exec -T n8n-db   dropdb -U "$N8N_DB_USER" --if-exists --force "$N8N_DB_NAME"
"${compose[@]}" exec -T n8n-db   createdb -U "$N8N_DB_USER" -O "$N8N_DB_USER" "$N8N_DB_NAME"
"${compose[@]}" exec -T n8n-db   pg_restore -U "$N8N_DB_USER" -d "$N8N_DB_NAME" --no-owner --no-privileges   < "$BACKUP_PATH/$n8n_dump"

echo "Restoring reporting PostgreSQL database..."
"${compose[@]}" exec -T reporting-db   dropdb -U "$REPORTING_DB_ADMIN_USER" --if-exists --force "$REPORTING_DB_NAME"
"${compose[@]}" exec -T reporting-db   createdb -U "$REPORTING_DB_ADMIN_USER" -O "$REPORTING_DB_ADMIN_USER" "$REPORTING_DB_NAME"
"${compose[@]}" exec -T reporting-db   pg_restore -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" --no-owner --no-privileges   < "$BACKUP_PATH/$reporting_dump"

echo "Restoring n8n persistent data volume..."
"${compose[@]}" run --rm --no-deps -T --user 0:0 --entrypoint sh n8n -lc   'find /home/node/.n8n -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; tar -xzf - -C /home/node/.n8n; chown -R 1000:1000 /home/node/.n8n'   < "$BACKUP_PATH/$n8n_archive"

echo "Starting Agent v2 stack and waiting for health..."
"${compose[@]}" up -d --wait

bash "$ROOT_DIR/scripts/healthcheck.sh"

restore_failed=0
trap - EXIT

echo "PASS: Agent v2 live restore completed."
echo "RESTORED_FROM=$BACKUP_PATH"
echo "PRE_RESTORE_BACKUP=$pre_restore_path"

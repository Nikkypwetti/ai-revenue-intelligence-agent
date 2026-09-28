#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT_DIR/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
LOCK_FILE="${BACKUP_LOCK_FILE:-/tmp/revint-agent-v2-backup.lock}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ "$BACKUP_ROOT" != "/" && -n "$BACKUP_ROOT" ]] || fail "unsafe BACKUP_ROOT."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  COMPOSE_PROJECT_NAME
  N8N_DB_NAME N8N_DB_USER
  REPORTING_DB_NAME REPORTING_DB_ADMIN_USER
  N8N_ENCRYPTION_KEY
)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || fail "$name is missing or uses a placeholder."
done

command -v docker >/dev/null || fail "docker is not available."
command -v sha256sum >/dev/null || fail "sha256sum is not available."
command -v tar >/dev/null || fail "tar is not available."
command -v flock >/dev/null || fail "flock is not available."

exec 9>"$LOCK_FILE"
flock -n 9 || fail "another Agent v2 backup is already running."

mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
staging="$BACKUP_ROOT/.incomplete-$timestamp-$$"
final="$BACKUP_ROOT/$timestamp"
mkdir -m 700 "$staging"

cleanup() {
  if [[ -d "$staging" ]]; then
    rm -rf -- "$staging"
  fi
}
trap cleanup EXIT

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

running_services="$("${compose[@]}" ps --services --status running)"
for service in n8n-db reporting-db; do
  grep -qx "$service" <<<"$running_services" ||     fail "required database service is not running: $service"
done

echo "Backing up n8n PostgreSQL state..."
"${compose[@]}" exec -T n8n-db   pg_dump -U "$N8N_DB_USER" -d "$N8N_DB_NAME"   --format=custom --compress=6 --no-owner --no-privileges   > "$staging/n8n-db.dump"

echo "Backing up reporting PostgreSQL state..."
"${compose[@]}" exec -T reporting-db   pg_dump -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME"   --format=custom --compress=6 --no-owner --no-privileges   > "$staging/reporting-db.dump"

echo "Backing up Agent v2 n8n data volume..."
"${compose[@]}" run --rm --no-deps -T --user 0:0 --entrypoint sh n8n -lc   'cd /home/node/.n8n && tar -czf - .'   > "$staging/n8n-data.tar.gz"

[[ -s "$staging/n8n-db.dump" ]] || fail "n8n database dump is empty."
[[ -s "$staging/reporting-db.dump" ]] || fail "reporting database dump is empty."
[[ -s "$staging/n8n-data.tar.gz" ]] || fail "n8n data archive is empty."

"${compose[@]}" exec -T n8n-db pg_restore --list < "$staging/n8n-db.dump" >/dev/null
"${compose[@]}" exec -T reporting-db pg_restore --list < "$staging/reporting-db.dump" >/dev/null
tar -tzf "$staging/n8n-data.tar.gz" >/dev/null

encryption_fingerprint="$(printf '%s' "$N8N_ENCRYPTION_KEY" | sha256sum | awk '{print $1}')"
git_commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')"
n8n_version="${N8N_VERSION:-unknown}"
postgres_version="${POSTGRES_VERSION:-unknown}"

cat > "$staging/manifest.env" <<EOF
BACKUP_FORMAT_VERSION=1
BACKUP_CREATED_AT_UTC=$timestamp
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME
SOURCE_GIT_COMMIT=$git_commit
N8N_VERSION=$n8n_version
POSTGRES_VERSION=$postgres_version
N8N_DB_NAME=$N8N_DB_NAME
REPORTING_DB_NAME=$REPORTING_DB_NAME
N8N_ENCRYPTION_KEY_SHA256=$encryption_fingerprint
N8N_DB_DUMP=n8n-db.dump
REPORTING_DB_DUMP=reporting-db.dump
N8N_DATA_ARCHIVE=n8n-data.tar.gz
EOF

(
  cd "$staging"
  sha256sum manifest.env n8n-db.dump reporting-db.dump n8n-data.tar.gz > SHA256SUMS
)

mv "$staging" "$final"
trap - EXIT

if [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d     -name '20??????T??????Z' -mtime "+$BACKUP_RETENTION_DAYS"     -print -exec rm -rf -- {} +
else
  fail "BACKUP_RETENTION_DAYS must be a non-negative integer."
fi

echo "PASS: Agent v2 backup created."
echo "BACKUP_PATH=$final"

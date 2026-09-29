#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
OFFSITE_ENV_FILE="${OFFSITE_ENV_FILE:-$ROOT_DIR/deploy/offsite-backup.env}"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT_DIR/backups}"
LOCK_FILE="${OFFSITE_BACKUP_LOCK_FILE:-/tmp/revint-agent-v2-offsite-backup.lock}"

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ -f "$OFFSITE_ENV_FILE" ]] || fail "$OFFSITE_ENV_FILE does not exist."

set -a
source "$ENV_FILE"
source "$OFFSITE_ENV_FILE"
set +a

[[ "${OFFSITE_BACKUP_ENABLED:-false}" == "true" ]] || {
  echo "SKIP: encrypted off-site backup is disabled."
  exit 0
}

for name in AGE_RECIPIENT RCLONE_REMOTE; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || fail "$name is missing or placeholder."
done

command -v age >/dev/null || fail "age is not installed."
command -v rclone >/dev/null || fail "rclone is not installed."
command -v tar >/dev/null || fail "tar is not installed."
command -v sha256sum >/dev/null || fail "sha256sum is not installed."
command -v flock >/dev/null || fail "flock is not installed."

exec 9>"$LOCK_FILE"
flock -n 9 || fail "another off-site backup job is already running."

backup_output="$(BACKUP_ROOT="$BACKUP_ROOT" bash "$ROOT_DIR/scripts/backup-agent-v2.sh")"
printf '%s\n' "$backup_output"
backup_path="$(awk -F= '$1=="BACKUP_PATH" {print $2}' <<<"$backup_output" | tail -1)"
[[ -d "$backup_path" ]] || fail "local backup path was not created."

backup_name="$(basename "$backup_path")"
tmp_dir="$(mktemp -d)"
cleanup(){ rm -rf -- "$tmp_dir"; }
trap cleanup EXIT

archive="$tmp_dir/revint-agent-v2-$backup_name.tar"
encrypted="$archive.age"
checksum="$encrypted.sha256"

tar -C "$(dirname "$backup_path")" -cf "$archive" "$backup_name"
age -r "$AGE_RECIPIENT" -o "$encrypted" "$archive"
rm -f -- "$archive"

[[ -s "$encrypted" ]] || fail "encrypted archive is empty."
sha256sum "$encrypted" > "$checksum"

remote_base="${RCLONE_REMOTE%/}"
remote_path="$remote_base/$backup_name"
rclone mkdir "$remote_path"
rclone copyto "$encrypted" "$remote_path/$(basename "$encrypted")"
rclone copyto "$checksum" "$remote_path/$(basename "$checksum")"

remote_size="$(rclone size "$remote_path" --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("bytes",0))')"
local_size="$(stat -c %s "$encrypted")"
[[ "$remote_size" -ge "$local_size" ]] || fail "remote encrypted backup verification failed."

echo "PASS: encrypted Agent V2 backup replicated off-site."
echo "OFFSITE_BACKUP_PATH=$remote_path"

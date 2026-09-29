#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT_DIR/backups}"
BACKUP_PATH="${1:-}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ "${OFFSITE_BACKUP_ENABLED:-false}" == "true" ]] || {
  echo "FAIL: OFFSITE_BACKUP_ENABLED is not true."
  exit 1
}
: "${OFFSITE_BACKUP_RECIPIENT:?Missing OFFSITE_BACKUP_RECIPIENT}"
: "${OFFSITE_BACKUP_RCLONE_REMOTE:?Missing OFFSITE_BACKUP_RCLONE_REMOTE}"
: "${OFFSITE_BACKUP_RCLONE_PATH:?Missing OFFSITE_BACKUP_RCLONE_PATH}"

command -v age >/dev/null || { echo "FAIL: age is not installed."; exit 1; }
command -v rclone >/dev/null || { echo "FAIL: rclone is not installed."; exit 1; }

if [[ -z "$BACKUP_PATH" ]]; then
  BACKUP_PATH="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
fi
[[ -d "$BACKUP_PATH" ]] || { echo "FAIL: backup directory not found."; exit 1; }
[[ -f "$BACKUP_PATH/SHA256SUMS" ]] || { echo "FAIL: backup checksums are missing."; exit 1; }

(
  cd "$BACKUP_PATH"
  sha256sum -c SHA256SUMS >/dev/null
)

backup_name="$(basename "$BACKUP_PATH")"
tmp_dir="$(mktemp -d)"
cleanup(){ rm -rf "$tmp_dir"; }
trap cleanup EXIT
archive="$tmp_dir/revint-agent-v2-$backup_name.tar.gz.age"
checksum="$archive.sha256"

tar -C "$(dirname "$BACKUP_PATH")" -czf - "$backup_name" |
  age -r "$OFFSITE_BACKUP_RECIPIENT" -o "$archive"
sha256sum "$archive" > "$checksum"

remote="${OFFSITE_BACKUP_RCLONE_REMOTE%:}:"
remote_path="${OFFSITE_BACKUP_RCLONE_PATH#/}"
rclone copyto "$archive" "$remote/$remote_path/$(basename "$archive")"
rclone copyto "$checksum" "$remote/$remote_path/$(basename "$checksum")"

rclone lsf "$remote/$remote_path/" | grep -Fxq "$(basename "$archive")"
rclone lsf "$remote/$remote_path/" | grep -Fxq "$(basename "$checksum")"

echo "PASS: encrypted Agent V2 backup replicated off-site."
echo "OFFSITE_OBJECT=$remote/$remote_path/$(basename "$archive")"


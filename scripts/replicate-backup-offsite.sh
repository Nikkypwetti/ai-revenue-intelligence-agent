#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  BACKUP_AGE_RECIPIENT='age1...' \
  BACKUP_RCLONE_REMOTE='gdrive:revint-agent-backups' \
  bash scripts/replicate-backup-offsite.sh \
    [--backup backups/<timestamp>] \
    --confirm REVINT_OFFSITE_BACKUP

Requirements: age + rclone. The backup is encrypted locally before upload.
The age private key must be kept separately from the backup destination.
EOF
      exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$CONFIRM" == "REVINT_OFFSITE_BACKUP" ]] || fail "confirmation token is missing."
command -v age >/dev/null || fail "age is not installed."
command -v rclone >/dev/null || fail "rclone is not installed."
command -v sha256sum >/dev/null || fail "sha256sum is not installed."

: "${BACKUP_AGE_RECIPIENT:?Missing BACKUP_AGE_RECIPIENT}"
: "${BACKUP_RCLONE_REMOTE:?Missing BACKUP_RCLONE_REMOTE}"

if [[ -z "$BACKUP_PATH" ]]; then
  latest="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20??????T??????Z' -printf '%f\n' 2>/dev/null | sort | tail -1)"
  [[ -n "$latest" ]] || fail "no completed backup exists under $BACKUP_ROOT."
  BACKUP_PATH="$BACKUP_ROOT/$latest"
fi

BACKUP_PATH="$(readlink -f "$BACKUP_PATH")"
[[ -d "$BACKUP_PATH" ]] || fail "backup does not exist: $BACKUP_PATH"
[[ -f "$BACKUP_PATH/SHA256SUMS" && -f "$BACKUP_PATH/manifest.env" ]] || fail "backup is incomplete."

(
  cd "$BACKUP_PATH"
  sha256sum -c SHA256SUMS >/dev/null
)

name="$(basename "$BACKUP_PATH")"
tmpdir="$(mktemp -d)"
cleanup(){ rm -rf -- "$tmpdir"; }
trap cleanup EXIT

archive="$tmpdir/$name.tar.gz"
encrypted="$tmpdir/$name.tar.gz.age"
checksum="$tmpdir/$name.tar.gz.age.sha256"

tar -C "$(dirname "$BACKUP_PATH")" -czf "$archive" "$name"
age -r "$BACKUP_AGE_RECIPIENT" -o "$encrypted" "$archive"
sha256sum "$encrypted" > "$checksum"
rm -f "$archive"

remote_base="${BACKUP_RCLONE_REMOTE%/}"
rclone copyto "$encrypted" "$remote_base/$name.tar.gz.age"
rclone copyto "$checksum" "$remote_base/$name.tar.gz.age.sha256"

rclone lsf "$remote_base" --files-only | grep -Fxq "$name.tar.gz.age" || fail "encrypted backup is not visible on remote."
rclone lsf "$remote_base" --files-only | grep -Fxq "$name.tar.gz.age.sha256" || fail "checksum is not visible on remote."

echo "PASS: encrypted off-device backup replicated."
echo "REMOTE_OBJECT=$remote_base/$name.tar.gz.age"
echo "NOTE=Keep the age private key outside the backup destination."

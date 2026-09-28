#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINUTE="${BACKUP_CRON_MINUTE:-30}"
HOUR="${BACKUP_CRON_HOUR:-2}"
MARKER_BEGIN="# BEGIN REVINT_AGENT_V2_BACKUP"
MARKER_END="# END REVINT_AGENT_V2_BACKUP"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v crontab >/dev/null || fail "crontab is not available."
[[ "$MINUTE" =~ ^([0-9]|[1-5][0-9])$ ]] || fail "BACKUP_CRON_MINUTE must be 0-59."
[[ "$HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || fail "BACKUP_CRON_HOUR must be 0-23."

mkdir -p "$ROOT_DIR/backups"

current="$(crontab -l 2>/dev/null || true)"
cleaned="$(awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
  $0 == begin {skip=1; next}
  $0 == end {skip=0; next}
  !skip {print}
' <<<"$current")"

job="cd '$ROOT_DIR' && mkdir -p '$ROOT_DIR/backups' && bash '$ROOT_DIR/scripts/backup-agent-v2.sh' >> '$ROOT_DIR/backups/backup.log' 2>&1"

{
  printf '%s\n' "$cleaned"
  printf '%s\n' "$MARKER_BEGIN"
  printf '%s %s * * * %s\n' "$MINUTE" "$HOUR" "$job"
  printf '%s\n' "$MARKER_END"
} | awk 'NF || prev {print} {prev=NF}' | crontab -

echo "PASS: Agent v2 daily backup cron installed."
echo "SCHEDULE=$MINUTE $HOUR * * *"
echo "BACKUP_ROOT=$ROOT_DIR/backups"

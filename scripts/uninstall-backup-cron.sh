#!/usr/bin/env bash
set -euo pipefail

MARKER_BEGIN="# BEGIN REVINT_AGENT_V2_BACKUP"
MARKER_END="# END REVINT_AGENT_V2_BACKUP"

current="$(crontab -l 2>/dev/null || true)"
cleaned="$(awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
  $0 == begin {skip=1; next}
  $0 == end {skip=0; next}
  !skip {print}
' <<<"$current")"

printf '%s\n' "$cleaned" | crontab -

echo "PASS: Agent v2 backup cron removed."

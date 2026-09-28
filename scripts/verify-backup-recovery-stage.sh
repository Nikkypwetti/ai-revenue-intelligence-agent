#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT_DIR/backups}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cd "$ROOT_DIR"

for script in   scripts/backup-agent-v2.sh   scripts/verify-backup-recovery.sh   scripts/restore-agent-v2.sh   scripts/install-backup-cron.sh   scripts/uninstall-backup-cron.sh; do
  bash -n "$script"
done

git check-ignore -q backups/ || fail "backups/ is not Git-ignored."

latest="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d   -name '20??????T??????Z' -printf '%f
' 2>/dev/null | sort | tail -1)"
[[ -n "$latest" ]] || fail "no completed Agent v2 backup exists."
latest_path="$BACKUP_ROOT/$latest"

[[ "$(stat -c '%a' "$latest_path")" == "700" ]] ||   fail "latest backup directory is not mode 700."

while IFS= read -r artifact; do
  [[ "$(stat -c '%a' "$artifact")" == "600" ]] ||     fail "backup artifact is not mode 600: $artifact"
done < <(find "$latest_path" -mindepth 1 -maxdepth 1 -type f -print)

bash scripts/verify-backup-recovery.sh "$latest_path"

if bash scripts/restore-agent-v2.sh   --backup "$latest_path"   --confirm WRONG_CONFIRMATION_TOKEN >/tmp/revint-restore-guard.out 2>&1; then
  fail "live restore accepted an invalid confirmation token."
fi
grep -q 'live restore confirmation token is missing' /tmp/revint-restore-guard.out ||   fail "live restore confirmation guard did not fail for the expected reason."
rm -f /tmp/revint-restore-guard.out

cron_state="$(crontab -l 2>/dev/null || true)"
marker_count="$(grep -c '^# BEGIN REVINT_AGENT_V2_BACKUP$' <<<"$cron_state" || true)"
job_count="$(grep -c "scripts/backup-agent-v2.sh" <<<"$cron_state" || true)"
[[ "$marker_count" == "1" && "$job_count" == "1" ]] ||   fail "Agent v2 backup cron is missing or duplicated."
grep -q "^30 2 \* \* \*" <<<"$cron_state" ||   fail "Agent v2 backup cron is not scheduled for 02:30."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

temp_db_count="$(
  "${compose[@]}" exec -T n8n-db     psql -X -q -A -t -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
      SELECT count(*) FROM pg_database
      WHERE datname LIKE 'revint_n8n_verify_%';
    "
)"
[[ "$temp_db_count" == "0" ]] || fail "temporary n8n restore-verification databases remain."

temp_reporting_count="$(
  "${compose[@]}" exec -T reporting-db     psql -X -q -A -t -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
      SELECT count(*) FROM pg_database
      WHERE datname LIKE 'revint_reporting_verify_%';
    "
)"
[[ "$temp_reporting_count" == "0" ]] ||   fail "temporary reporting restore-verification databases remain."

bash "$ROOT_DIR/scripts/verify-runtime-isolation.sh"

echo "PASS: backup artifacts are owner-only and Git-ignored."
echo "PASS: checksum, encryption-key, database restore, and n8n archive recovery drill passed."
echo "PASS: guarded live restore rejects invalid confirmation before touching live state."
echo "PASS: daily 02:30 backup cron is installed exactly once."
echo "PASS: restore-verification temporary databases are cleaned."
echo "PASS: Agent v2 runtime isolation verification passed."

bash "$ROOT_DIR/scripts/verify-observability-core.sh"

echo "PASS: backup and recovery stage verification passed."

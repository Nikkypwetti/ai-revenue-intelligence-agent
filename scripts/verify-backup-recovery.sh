#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT_DIR/backups}"
BACKUP_PATH="${1:-}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "$BACKUP_PATH" ]]; then
  BACKUP_PATH="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d     -name '20??????T??????Z' -printf '%f
' 2>/dev/null | sort | tail -1)"
  [[ -n "$BACKUP_PATH" ]] || fail "no completed backup exists under $BACKUP_ROOT."
  BACKUP_PATH="$BACKUP_ROOT/$BACKUP_PATH"
fi

[[ -d "$BACKUP_PATH" ]] || fail "backup directory does not exist: $BACKUP_PATH"
[[ -f "$BACKUP_PATH/manifest.env" ]] || fail "manifest.env is missing."
[[ -f "$BACKUP_PATH/SHA256SUMS" ]] || fail "SHA256SUMS is missing."

(
  cd "$BACKUP_PATH"
  sha256sum -c SHA256SUMS
) >/dev/null

manifest_value() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$BACKUP_PATH/manifest.env"
}

backup_format_version="$(manifest_value BACKUP_FORMAT_VERSION)"
backup_project_name="$(manifest_value COMPOSE_PROJECT_NAME)"
backup_n8n_db_name="$(manifest_value N8N_DB_NAME)"
backup_reporting_db_name="$(manifest_value REPORTING_DB_NAME)"
backup_key_fingerprint="$(manifest_value N8N_ENCRYPTION_KEY_SHA256)"
n8n_db_dump="$(manifest_value N8N_DB_DUMP)"
reporting_db_dump="$(manifest_value REPORTING_DB_DUMP)"
n8n_data_archive="$(manifest_value N8N_DATA_ARCHIVE)"

[[ "$backup_format_version" == "1" ]] || fail "unsupported backup format version."
[[ "$backup_project_name" == "$COMPOSE_PROJECT_NAME" ]] ||   fail "backup project name does not match the current deployment."
[[ "$backup_n8n_db_name" == "$N8N_DB_NAME" ]] ||   fail "backup n8n database name does not match the current deployment."
[[ "$backup_reporting_db_name" == "$REPORTING_DB_NAME" ]] ||   fail "backup reporting database name does not match the current deployment."
[[ -n "$n8n_db_dump" && -n "$reporting_db_dump" && -n "$n8n_data_archive" ]] ||   fail "backup manifest is missing required artifact names."

current_key_fingerprint="$(printf '%s' "$N8N_ENCRYPTION_KEY" | sha256sum | awk '{print $1}')"
[[ "$current_key_fingerprint" == "$backup_key_fingerprint" ]] ||   fail "current N8N_ENCRYPTION_KEY does not match the backup fingerprint."

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

"${compose[@]}" exec -T n8n-db pg_restore --list < "$BACKUP_PATH/$n8n_db_dump" >/dev/null
"${compose[@]}" exec -T reporting-db pg_restore --list < "$BACKUP_PATH/$reporting_db_dump" >/dev/null

archive_listing="$(tar -tzf "$BACKUP_PATH/$n8n_data_archive")"
if grep -Eq '(^/|(^|/)\.\.(/|$))' <<<"$archive_listing"; then
  fail "n8n data archive contains an unsafe path."
fi

verify_suffix="verify_$$"
n8n_verify_db="revint_n8n_$verify_suffix"
reporting_verify_db="revint_reporting_$verify_suffix"
tmpdir="$(mktemp -d)"

cleanup() {
  rm -rf -- "$tmpdir"
  "${compose[@]}" exec -T n8n-db dropdb -U "$N8N_DB_USER" --if-exists "$n8n_verify_db" >/dev/null 2>&1 || true
  "${compose[@]}" exec -T reporting-db dropdb -U "$REPORTING_DB_ADMIN_USER" --if-exists "$reporting_verify_db" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${compose[@]}" exec -T n8n-db createdb -U "$N8N_DB_USER" "$n8n_verify_db"
"${compose[@]}" exec -T reporting-db createdb -U "$REPORTING_DB_ADMIN_USER" "$reporting_verify_db"

"${compose[@]}" exec -T n8n-db   pg_restore -U "$N8N_DB_USER" -d "$n8n_verify_db" --no-owner --no-privileges   < "$BACKUP_PATH/$n8n_db_dump"

"${compose[@]}" exec -T reporting-db   pg_restore -U "$REPORTING_DB_ADMIN_USER" -d "$reporting_verify_db" --no-owner --no-privileges   < "$BACKUP_PATH/$reporting_db_dump"

n8n_state="$("${compose[@]}" exec -T n8n-db   psql -X -q -A -t -U "$N8N_DB_USER" -d "$n8n_verify_db" -c "
    SELECT
      (to_regclass('public.workflow_entity') IS NOT NULL)::int || '|' ||
      (to_regclass('public.credentials_entity') IS NOT NULL)::int || '|' ||
      (SELECT count(*) FROM workflow_entity);
  ")"

IFS='|' read -r n8n_workflow_table n8n_credential_table n8n_workflow_count <<< "$n8n_state"
[[ "$n8n_workflow_table" == "1" && "$n8n_credential_table" == "1" ]] ||   fail "restored n8n database is missing required tables."
[[ "$n8n_workflow_count" =~ ^[0-9]+$ && "$n8n_workflow_count" -ge 4 ]] ||   fail "restored n8n database does not contain the expected Agent v2 workflows."

reporting_state="$("${compose[@]}" exec -T reporting-db   psql -X -q -A -t -U "$REPORTING_DB_ADMIN_USER" -d "$reporting_verify_db" -c "
    SELECT
      (to_regclass('governance.kpi_catalog') IS NOT NULL)::int || '|' ||
      (to_regclass('reporting.deals') IS NOT NULL)::int || '|' ||
      (to_regclass('audit.agent_events') IS NOT NULL)::int || '|' ||
      (to_regclass('observability.component_status') IS NOT NULL)::int || '|' ||
      (SELECT count(*) FROM governance.kpi_catalog WHERE active);
  ")"

IFS='|' read -r kpi_table deals_table audit_table obs_view active_kpis <<< "$reporting_state"
[[ "$kpi_table" == "1" && "$deals_table" == "1" && "$audit_table" == "1" && "$obs_view" == "1" ]] ||   fail "restored reporting database is missing governed runtime objects."
[[ "$active_kpis" == "4" ]] || fail "restored KPI catalogue does not contain four active KPIs."

mkdir -p "$tmpdir/n8n-data"
tar -xzf "$BACKUP_PATH/$n8n_data_archive" -C "$tmpdir/n8n-data"
[[ -d "$tmpdir/n8n-data" ]] || fail "n8n data archive could not be extracted."

echo "PASS: checksums and encryption-key fingerprint verified."
echo "PASS: n8n PostgreSQL backup restored into isolated verification database."
echo "PASS: reporting PostgreSQL backup restored with governed schemas and four active KPIs."
echo "PASS: n8n data archive is path-safe and extractable."
echo "PASS: backup recovery verification passed."

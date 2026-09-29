#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
OUTPUT_ROOT="${POWERBI_EXPORT_ROOT:-$ROOT_DIR/exports/powerbi}"
CONFIRM=""

fail(){ echo "FAIL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage:
  bash scripts/export-powerbi-dataset.sh --confirm REVINT_POWERBI_EXPORT

Creates a local, read-only Power BI handoff package from canonical Agent V2 data.
No CRM source is mutated and no public endpoint is created.
EOF
      exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$CONFIRM" == "REVINT_POWERBI_EXPORT" ]] || fail "Power BI export confirmation token is missing or incorrect."
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."

set -a
source "$ENV_FILE"
set +a

required=(REPORTING_DB_NAME REPORTING_DB_READER_USER REPORTING_DB_READER_PASSWORD)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || fail "$name is missing or placeholder."
done

command -v sha256sum >/dev/null || fail "sha256sum is unavailable."

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
staging="$OUTPUT_ROOT/.incomplete-$timestamp-$$"
final="$OUTPUT_ROOT/$timestamp"
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"
mkdir -m 700 "$staging"

cleanup(){
  [[ ! -d "$staging" ]] || rm -rf -- "$staging"
}
trap cleanup EXIT

psql_reader(){
  "${compose[@]}" exec -T -e PGPASSWORD="$REPORTING_DB_READER_PASSWORD" reporting-db     psql -X -q -v ON_ERROR_STOP=1 -U "$REPORTING_DB_READER_USER" -d "$REPORTING_DB_NAME" "$@"
}

# Canonical management dataset. This export is intentionally business-wide and
# should be treated as a trusted analytics artifact, not a per-user RBAC surface.
psql_reader -c "\copy (
  SELECT *
  FROM reporting.deals
  ORDER BY source_updated_at DESC NULLS LAST, connector_key, source_record_id
) TO STDOUT WITH (FORMAT CSV, HEADER true)" > "$staging/deals.csv"

# Operational status is safe for management/ops visibility and excludes raw errors.
psql_reader -c "\copy (
  SELECT *
  FROM observability.component_status
  ORDER BY component_key
) TO STDOUT WITH (FORMAT CSV, HEADER true)" > "$staging/component_status.csv"

psql_reader -c "\copy (
  SELECT *
  FROM observability.runtime_status
) TO STDOUT WITH (FORMAT CSV, HEADER true)" > "$staging/runtime_status.csv"

[[ -s "$staging/deals.csv" ]] || fail "deals.csv is empty."
[[ -s "$staging/component_status.csv" ]] || fail "component_status.csv is empty."
[[ -s "$staging/runtime_status.csv" ]] || fail "runtime_status.csv is empty."

deal_rows="$(($(wc -l < "$staging/deals.csv") - 1))"
component_rows="$(($(wc -l < "$staging/component_status.csv") - 1))"

cat > "$staging/manifest.env" <<EOF
POWERBI_EXPORT_VERSION=1
CREATED_AT_UTC=$timestamp
SOURCE=Agent_V2_Canonical_Reporting
DEALS_ROWS=$deal_rows
COMPONENT_STATUS_ROWS=$component_rows
DATA_SCOPE=business_wide_management_extract
FILES=deals.csv,component_status.csv,runtime_status.csv
EOF

(
  cd "$staging"
  sha256sum deals.csv component_status.csv runtime_status.csv manifest.env > SHA256SUMS
)

mv "$staging" "$final"
trap - EXIT

echo "PASS: Power BI local handoff dataset created from read-only canonical reporting data."
echo "POWERBI_EXPORT_PATH=$final"
echo "DEALS_ROWS=$deal_rows"
echo "NOTE=Treat this export as a trusted business-wide management artifact."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

psql_admin() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_ADMIN_USER" \
    -d "$REPORTING_DB_NAME" \
    "$@"
}

for role_name in "$REPORTING_DB_READER_USER" "$AUDIT_DB_WRITER_USER"; do
  [[ "$role_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "FAIL: invalid PostgreSQL role name: $role_name"
    exit 1
  }
done

business_count="$(psql_admin -c "SELECT count(*) FROM governance.business_config;")"
kpi_count="$(psql_admin -c "SELECT count(*) FROM governance.kpi_catalog WHERE active;")"

[[ "$business_count" -ge 1 ]] || { echo "FAIL: no business configuration found."; exit 1; }
[[ "$kpi_count" -ge 4 ]] || { echo "FAIL: expected at least four active KPI definitions."; exit 1; }

reader_checks="$(psql_admin -c "SELECT
  has_schema_privilege('$REPORTING_DB_READER_USER','reporting','USAGE')::int,
  has_table_privilege('$REPORTING_DB_READER_USER','governance.business_config','SELECT')::int,
  has_table_privilege('$REPORTING_DB_READER_USER','governance.kpi_catalog','SELECT')::int,
  has_table_privilege('$REPORTING_DB_READER_USER','governance.business_config','UPDATE')::int;")"

IFS='|' read -r reader_reporting reader_business reader_kpis reader_update <<< "$reader_checks"

[[ "$reader_reporting" == "1" ]] || { echo "FAIL: reporting reader lacks reporting schema access."; exit 1; }
[[ "$reader_business" == "1" ]] || { echo "FAIL: reporting reader cannot read business config."; exit 1; }
[[ "$reader_kpis" == "1" ]] || { echo "FAIL: reporting reader cannot read KPI catalogue."; exit 1; }
[[ "$reader_update" == "0" ]] || { echo "FAIL: reporting reader unexpectedly has governance UPDATE access."; exit 1; }

audit_checks="$(psql_admin -c "SELECT
  has_table_privilege('$AUDIT_DB_WRITER_USER','audit.agent_events','INSERT')::int,
  has_table_privilege('$AUDIT_DB_WRITER_USER','audit.agent_events','SELECT')::int,
  has_schema_privilege('$AUDIT_DB_WRITER_USER','reporting','USAGE')::int,
  has_table_privilege('$AUDIT_DB_WRITER_USER','governance.business_config','SELECT')::int;")"

IFS='|' read -r audit_insert audit_select audit_reporting audit_governance <<< "$audit_checks"

[[ "$audit_insert" == "1" ]] || { echo "FAIL: audit writer lacks INSERT permission."; exit 1; }
[[ "$audit_select" == "0" ]] || { echo "FAIL: audit writer unexpectedly has audit SELECT permission."; exit 1; }
[[ "$audit_reporting" == "0" ]] || { echo "FAIL: audit writer unexpectedly has reporting schema access."; exit 1; }
[[ "$audit_governance" == "0" ]] || { echo "FAIL: audit writer unexpectedly has governance read access."; exit 1; }

event_id="stage2-security-check-$(date +%s)"
psql_admin -c "SET ROLE \"$AUDIT_DB_WRITER_USER\";
  INSERT INTO audit.agent_events (event_id,event_type,stage,payload)
  VALUES ('$event_id','security_verification','stage2','{}'::jsonb);
  RESET ROLE;
  DELETE FROM audit.agent_events WHERE event_id='$event_id';"

reader_business_count="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T \
  -e PGPASSWORD="$REPORTING_DB_READER_PASSWORD" reporting-db \
  psql -h 127.0.0.1 -U "$REPORTING_DB_READER_USER" -d "$REPORTING_DB_NAME" -X -q -A -t \
  -c "SELECT count(*) FROM governance.business_config;")"

[[ "$reader_business_count" -ge 1 ]] || {
  echo "FAIL: reporting reader login could not read business configuration."
  exit 1
}

if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T \
  -e PGPASSWORD="$REPORTING_DB_READER_PASSWORD" reporting-db \
  psql -h 127.0.0.1 -U "$REPORTING_DB_READER_USER" -d "$REPORTING_DB_NAME" \
  -v ON_ERROR_STOP=1 -c "UPDATE governance.business_config SET updated_at=updated_at;" \
  >/dev/null 2>&1; then
  echo "FAIL: reporting reader unexpectedly performed a governance UPDATE."
  exit 1
fi

login_event_id="stage2-login-check-$(date +%s)"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T \
  -e PGPASSWORD="$AUDIT_DB_WRITER_PASSWORD" reporting-db \
  psql -h 127.0.0.1 -U "$AUDIT_DB_WRITER_USER" -d "$REPORTING_DB_NAME" \
  -v ON_ERROR_STOP=1 -c "INSERT INTO audit.agent_events (event_id,event_type,stage,payload)
  VALUES ('$login_event_id','credential_verification','stage2','{}'::jsonb);" \
  >/dev/null

if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T \
  -e PGPASSWORD="$AUDIT_DB_WRITER_PASSWORD" reporting-db \
  psql -h 127.0.0.1 -U "$AUDIT_DB_WRITER_USER" -d "$REPORTING_DB_NAME" \
  -v ON_ERROR_STOP=1 -c "SELECT * FROM governance.business_config;" \
  >/dev/null 2>&1; then
  echo "FAIL: audit writer unexpectedly read governance configuration."
  exit 1
fi

psql_admin -c "DELETE FROM audit.agent_events WHERE event_id='$login_event_id';" >/dev/null

echo "PASS: client business configuration exists."
echo "PASS: governed KPI catalogue contains $kpi_count active definitions."
echo "PASS: reporting reader has read-only reporting/governance access."
echo "PASS: audit writer can insert audit events without reporting/governance read access."
echo "PASS: reporting reader and audit writer passwords authenticate successfully."
echo "PASS: runtime credential boundaries hold under direct PostgreSQL login."
echo "PASS: Stage 2 database security verification passed."

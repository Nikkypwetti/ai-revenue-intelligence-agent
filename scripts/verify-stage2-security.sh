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
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db     psql -X -q -A -t -v ON_ERROR_STOP=1     -U "$REPORTING_DB_ADMIN_USER"     -d "$REPORTING_DB_NAME"     "$@"
}

business_count="$(psql_admin -c "SELECT count(*) FROM governance.business_config;")"
kpi_count="$(psql_admin -c "SELECT count(*) FROM governance.kpi_catalog WHERE active;")"

[[ "$business_count" -ge 1 ]] || { echo "FAIL: no business configuration found."; exit 1; }
[[ "$kpi_count" -ge 4 ]] || { echo "FAIL: expected at least four active KPI definitions."; exit 1; }

reader_checks="$(psql_admin   -v reader_user="$REPORTING_DB_READER_USER"   -c "SELECT has_schema_privilege(:'reader_user','reporting','USAGE')::int,
             has_table_privilege(:'reader_user','governance.business_config','SELECT')::int,
             has_table_privilege(:'reader_user','governance.kpi_catalog','SELECT')::int,
             has_table_privilege(:'reader_user','governance.business_config','UPDATE')::int;")"

IFS='|' read -r reader_reporting reader_business reader_kpis reader_update <<< "$reader_checks"

[[ "$reader_reporting" == "1" ]] || { echo "FAIL: reporting reader lacks reporting schema access."; exit 1; }
[[ "$reader_business" == "1" ]] || { echo "FAIL: reporting reader cannot read business config."; exit 1; }
[[ "$reader_kpis" == "1" ]] || { echo "FAIL: reporting reader cannot read KPI catalogue."; exit 1; }
[[ "$reader_update" == "0" ]] || { echo "FAIL: reporting reader unexpectedly has governance UPDATE access."; exit 1; }

audit_checks="$(psql_admin   -v audit_user="$AUDIT_DB_WRITER_USER"   -c "SELECT has_table_privilege(:'audit_user','audit.agent_events','INSERT')::int,
             has_table_privilege(:'audit_user','audit.agent_events','SELECT')::int,
             has_schema_privilege(:'audit_user','reporting','USAGE')::int,
             has_table_privilege(:'audit_user','governance.business_config','SELECT')::int;")"

IFS='|' read -r audit_insert audit_select audit_reporting audit_governance <<< "$audit_checks"

[[ "$audit_insert" == "1" ]] || { echo "FAIL: audit writer lacks INSERT permission."; exit 1; }
[[ "$audit_select" == "0" ]] || { echo "FAIL: audit writer unexpectedly has audit SELECT permission."; exit 1; }
[[ "$audit_reporting" == "0" ]] || { echo "FAIL: audit writer unexpectedly has reporting schema access."; exit 1; }
[[ "$audit_governance" == "0" ]] || { echo "FAIL: audit writer unexpectedly has governance read access."; exit 1; }

event_id="stage2-security-check-$(date +%s)"
psql_admin   -v audit_user="$AUDIT_DB_WRITER_USER"   -v event_id="$event_id"   -c "SET ROLE :\"audit_user\";
      INSERT INTO audit.agent_events (event_id,event_type,stage,payload)
      VALUES (:'event_id','security_verification','stage2','{}'::jsonb);
      RESET ROLE;
      DELETE FROM audit.agent_events WHERE event_id=:'event_id';"

echo "PASS: client business configuration exists."
echo "PASS: governed KPI catalogue contains $kpi_count active definitions."
echo "PASS: reporting reader has read-only reporting/governance access."
echo "PASS: audit writer can insert audit events without reporting/governance read access."
echo "PASS: Stage 2 database security verification passed."

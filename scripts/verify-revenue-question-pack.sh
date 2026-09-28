#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
FIXTURE="$ROOT_DIR/database/fixtures/010_revenue_question_pack_verify.sql"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
[[ -f "$FIXTURE" ]] || { echo "FAIL: verification fixture is missing."; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  REPORTING_DB_ADMIN_USER REPORTING_DB_NAME
  REPORTING_DB_READER_USER REPORTING_DB_READER_PASSWORD
  CONNECTOR_DB_WRITER_USER CONNECTOR_DB_WRITER_PASSWORD
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
TEST_DB="revint_qpack_verify_$$"

if [[ ! "$TEST_DB" =~ ^[a-z0-9_]+$ ]]; then
  echo "FAIL: unsafe verification database name."
  exit 1
fi

cleanup() {
  "${compose[@]}" exec -T reporting-db dropdb \
    --if-exists -U "$REPORTING_DB_ADMIN_USER" "$TEST_DB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql_admin() {
  "${compose[@]}" exec -T reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_ADMIN_USER" -d "$TEST_DB" "$@"
}

psql_reader() {
  "${compose[@]}" exec -T -e PGPASSWORD="$REPORTING_DB_READER_PASSWORD" reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_READER_USER" -d "$TEST_DB" "$@"
}

psql_writer() {
  "${compose[@]}" exec -T -e PGPASSWORD="$CONNECTOR_DB_WRITER_PASSWORD" reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$CONNECTOR_DB_WRITER_USER" -d "$TEST_DB" "$@"
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $message — expected '$expected', got '$actual'."
    exit 1
  fi
}

echo "Creating isolated Revenue Question Pack verification database..."
"${compose[@]}" exec -T reporting-db createdb \
  -U "$REPORTING_DB_ADMIN_USER" "$TEST_DB"

"${compose[@]}" exec -T reporting-db pg_dump \
  -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" --no-owner \
  | "${compose[@]}" exec -T reporting-db \
      psql -X -v ON_ERROR_STOP=1 \
      -U "$REPORTING_DB_ADMIN_USER" -d "$TEST_DB" >/dev/null

REVENUE_PACK_DB_NAME="$TEST_DB" \
  bash "$ROOT_DIR/scripts/init-revenue-question-pack.sh" >/dev/null

psql_admin < "$FIXTURE" >/dev/null

catalog_state="$(psql_admin -c "
  SELECT
    (SELECT count(*) FROM governance.kpi_catalog WHERE active) || '|' ||
    (SELECT count(*) FROM governance.kpi_catalog k
      WHERE k.active
        AND EXISTS(
          SELECT 1 FROM governance.resolve_kpi_semantics(k.kpi_key,NULL)
        )) || '|' ||
    (SELECT count(*) FROM governance.data_domain_status WHERE active);
")"
assert_eq "$catalog_state" "37|37|6" \
  "37 KPI contracts and six source-neutral data domains did not resolve"

policy_drift="$(psql_admin -c "
  WITH expected_dim AS (
    SELECT k.kpi_key,k.version,u.dimension_key
    FROM governance.kpi_catalog k
    CROSS JOIN LATERAL unnest(k.allowed_dimensions) u(dimension_key)
    WHERE k.active
  ),
  actual_dim AS (
    SELECT kpi_key,kpi_version AS version,dimension_key
    FROM governance.kpi_dimension_policy
  ),
  expected_filter AS (
    SELECT k.kpi_key,k.version,u.filter_key
    FROM governance.kpi_catalog k
    CROSS JOIN LATERAL unnest(k.allowed_filters) u(filter_key)
    WHERE k.active
  ),
  actual_filter AS (
    SELECT kpi_key,kpi_version AS version,filter_key
    FROM governance.kpi_filter_policy
  )
  SELECT
    ((SELECT count(*) FROM (SELECT * FROM expected_dim EXCEPT SELECT * FROM actual_dim) x)
    +(SELECT count(*) FROM (SELECT * FROM actual_dim EXCEPT SELECT * FROM expected_dim) y))
    || '|' ||
    ((SELECT count(*) FROM (SELECT * FROM expected_filter EXCEPT SELECT * FROM actual_filter) x)
    +(SELECT count(*) FROM (SELECT * FROM actual_filter EXCEPT SELECT * FROM expected_filter) y));
")"
assert_eq "$policy_drift" "0|0" "KPI dimension/filter policy drift detected"

domain_state="$(psql_admin -c "
  SELECT count(*)
  FROM governance.data_domain_status
  WHERE active AND data_ready;
")"
assert_eq "$domain_state" "6"   "fixture ingestion did not activate all six data domains"

fixture_record_state="$(psql_admin -c "
  SELECT
    (SELECT count(*) FROM reporting.deals
      WHERE connector_key='verify_qp_deal') || '|' ||
    (SELECT count(*) FROM reporting.funnel_records
      WHERE connector_key='verify_qp_funnel') || '|' ||
    (SELECT count(*) FROM reporting.activities
      WHERE connector_key='verify_qp_activity') || '|' ||
    (SELECT count(*) FROM reporting.subscription_events
      WHERE connector_key='verify_qp_subscription') || '|' ||
    (SELECT count(*) FROM reporting.revenue_targets
      WHERE connector_key='verify_qp_target') || '|' ||
    (SELECT count(*) FROM reporting.forecast_snapshots
      WHERE connector_key='verify_qp_forecast');
")"
assert_eq "$fixture_record_state" "7|4|3|5|2|2"   "fixture connector-scoped record counts changed unexpectedly"

metric() {
  local key="$1"
  local filters="$2"
  psql_admin -c "
    SELECT governance.execute_agent_report_request_v2(
      'verify-qpack-admin','$key','this_month','metric_report',
      '[]'::jsonb,'$filters'::jsonb,'2026-09-15T12:00:00Z'
    ) #>> '{current_period,value}';
  "
}

assert_eq "$(metric closed_won_revenue '{"lead_source":"QPVerify"}')" "4000.00" "closed-won revenue"
assert_eq "$(metric open_pipeline '{"lead_source":"QPVerify"}')" "3000.00" "open pipeline"
assert_eq "$(metric weighted_pipeline '{"lead_source":"QPVerify"}')" "1000.00" "weighted pipeline"
assert_eq "$(metric win_rate '{"lead_source":"QPVerify"}')" "66.67" "win rate"
assert_eq "$(metric average_deal_size '{"lead_source":"QPVerify"}')" "2000.00" "average deal size"
assert_eq "$(metric average_acv '{"lead_source":"QPVerify"}')" "2400.00" "average ACV"
assert_eq "$(metric average_discount_percent '{"lead_source":"QPVerify"}')" "15.00" "average discount"
assert_eq "$(metric commit_forecast '{"lead_source":"QPVerify"}')" "1000.00" "commit forecast"
assert_eq "$(metric best_case_forecast '{"lead_source":"QPVerify"}')" "2000.00" "best-case forecast"

assert_eq "$(metric pipeline_coverage_ratio '{"sales_rep":["QP Alpha","QP Beta"]}')" "0.30" "pipeline coverage ratio"
assert_eq "$(metric quota_attainment '{"sales_rep":["QP Alpha","QP Beta"]}')" "40.00" "quota attainment"

assert_eq "$(metric lead_to_mql_rate '{"lead_source":"QPVerify"}')" "75.00" "lead-to-MQL conversion"
assert_eq "$(metric mql_to_sql_rate '{"lead_source":"QPVerify"}')" "66.67" "MQL-to-SQL conversion"
assert_eq "$(metric sql_to_opportunity_rate '{"lead_source":"QPVerify"}')" "100.00" "SQL-to-opportunity conversion"
assert_eq "$(metric opportunity_to_won_rate '{"lead_source":"QPVerify"}')" "50.00" "opportunity-to-won conversion"
assert_eq "$(metric speed_to_lead_hours '{"lead_source":"QPVerify"}')" "3.75" "speed-to-lead"

assert_eq "$(metric follow_up_sla_compliance '{"sales_rep":["QP Alpha","QP Beta"]}')" "33.33" "follow-up SLA compliance"
assert_eq "$(metric overdue_followups '{"sales_rep":["QP Alpha","QP Beta"]}')" "2" "overdue follow-ups"

assert_eq "$(metric current_mrr '{"sales_rep":["QP Alpha","QP Beta"]}')" "2000.00" "current MRR"
assert_eq "$(metric current_arr '{"sales_rep":["QP Alpha","QP Beta"]}')" "24000.00" "current ARR"
assert_eq "$(metric expansion_mrr '{"sales_rep":["QP Alpha","QP Beta"]}')" "500.00" "expansion MRR"
assert_eq "$(metric churned_mrr '{"sales_rep":["QP Alpha","QP Beta"]}')" "300.00" "churned MRR"
assert_eq "$(metric net_revenue_retention '{"sales_rep":["QP Alpha","QP Beta"]}')" "100.00" "NRR"
assert_eq "$(metric gross_revenue_retention '{"sales_rep":["QP Alpha","QP Beta"]}')" "75.00" "GRR"
assert_eq "$(metric forecast_accuracy '{"sales_rep":["QP Alpha","QP Beta"]}')" "75.00" "forecast accuracy"

assert_eq "$(metric missing_owner_deals '{"lead_source":"QPQuality"}')" "1" "missing-owner detection"
assert_eq "$(metric missing_close_date_deals '{"lead_source":"QPQuality"}')" "1" "missing close-date detection"
assert_eq "$(metric crm_data_quality_score '{"lead_source":"QPQuality"}')" "66.67" "CRM data-quality score"

breakdown_state="$(psql_admin -c "
  WITH report AS (
    SELECT governance.execute_agent_report_request_v2(
      'verify-qpack-admin','open_pipeline','this_month','breakdown_report',
      '[\"sales_rep\"]'::jsonb,'{\"lead_source\":\"QPVerify\"}'::jsonb,
      '2026-09-15T12:00:00Z'
    ) AS r
  ),
  rows AS (
    SELECT x.dimension_value,x.value
    FROM report,
    LATERAL jsonb_to_recordset(r #> '{current_period,rows}')
      AS x(dimension_value text,value numeric)
  )
  SELECT count(*) || '|' ||
         max(value) FILTER (WHERE dimension_value='QP Alpha') || '|' ||
         max(value) FILTER (WHERE dimension_value='QP Beta')
  FROM rows;
")"
assert_eq "$breakdown_state" "2|1000.00|2000.00" \
  "sales-rep pipeline breakdown"

diagnostic_state="$(psql_admin -c "
  WITH report AS (
    SELECT governance.execute_agent_report_request_v2(
      'verify-qpack-admin','open_pipeline','this_month','diagnostic_report',
      '[]'::jsonb,'{\"lead_source\":\"QPVerify\"}'::jsonb,
      '2026-09-15T12:00:00Z'
    ) AS r
  )
  SELECT
    r->>'status' || '|' ||
    (r #>> '{current_period,value}') || '|' ||
    (SELECT count(*) FROM jsonb_object_keys(r->'diagnostics'))
  FROM report;
")"
assert_eq "$diagnostic_state" "approved|3000.00|6" \
  "pipeline diagnostic report"

rep_scope="$(psql_admin -c "
  SELECT governance.execute_agent_report_request_v2(
    'verify-qpack-rep','open_pipeline','this_month','metric_report',
    '[]'::jsonb,'{\"lead_source\":\"QPVerify\"}'::jsonb,
    '2026-09-15T12:00:00Z'
  ) #>> '{current_period,value}';
")"
assert_eq "$rep_scope" "1000.00" "own-scope sales-rep enforcement"

incomplete_probability="$(psql_admin -c "
  WITH r AS (
    SELECT governance.execute_agent_report_request_v2(
      'verify-qpack-admin','weighted_pipeline','this_month','metric_report',
      '[]'::jsonb,jsonb_build_object('lead_source','QPIncomplete'),
      '2026-09-15T12:00:00Z'
    ) AS x
  )
  SELECT (x->>'status') || '|' || (x->>'reason')
  FROM r;
")"
assert_eq "$incomplete_probability" "unavailable|PROBABILITY_COVERAGE_INCOMPLETE" \
  "weighted pipeline did not fail closed on incomplete probability"

multi_dimension="$(psql_admin -c "
  SELECT
    governance.execute_agent_report_request_v2(
      'verify-qpack-admin','open_pipeline','this_month','breakdown_report',
      '[\"sales_rep\",\"deal_stage\"]'::jsonb,
      '{\"lead_source\":\"QPVerify\"}'::jsonb,
      '2026-09-15T12:00:00Z'
    )->>'reason';
")"
assert_eq "$multi_dimension" "MULTI_DIMENSION_NOT_SUPPORTED" \
  "multi-dimension request was not rejected"

psql_admin -c "
  UPDATE governance.data_domain_status
  SET data_ready=false
  WHERE domain_key='targets';
" >/dev/null

data_gate="$(psql_admin -c "
  WITH r AS (
    SELECT governance.execute_agent_report_request_v2(
      'verify-qpack-admin','quota_attainment','this_month','metric_report',
      '[]'::jsonb,'{\"sales_rep\":[\"QP Alpha\",\"QP Beta\"]}'::jsonb,
      '2026-09-15T12:00:00Z'
    ) AS x
  )
  SELECT (x->>'status') || '|' || (x->>'reason') || '|' ||
         (x->'missing_domains'->>0)
  FROM r;
")"
assert_eq "$data_gate" "unavailable|DATA_DOMAIN_NOT_READY|targets" \
  "missing client data domain did not fail closed"

psql_admin -c "
  UPDATE governance.data_domain_status
  SET data_ready=true
  WHERE domain_key='targets';
" >/dev/null

old_gateway="$(psql_admin -c "
  SELECT governance.execute_agent_metric_request(
    'verify-qpack-admin','closed_won_revenue','this_month','metric_report',
    '{\"lead_source\":\"QPVerify\"}'::jsonb,'2026-09-15T12:00:00Z'
  ) #>> '{current_period,value}';
")"
assert_eq "$old_gateway" "4000.00" \
  "backward-compatible four-KPI gateway changed behavior"

template_preserved="$(psql_admin -c "
  SELECT (position(
    'FROM reporting.deals'
    in (SELECT sql_template FROM governance.query_templates
        WHERE query_key='open_pipeline_v1')
  )>0)::int;
")"
assert_eq "$template_preserved" "1" "original V1 query template was overwritten"

privilege_state="$(psql_admin -c "
  SELECT
    has_table_privilege(
      '$REPORTING_DB_READER_USER','reporting.subscription_events','SELECT'
    )::int || '|' ||
    has_table_privilege(
      '$REPORTING_DB_READER_USER','reporting.subscription_events','INSERT'
    )::int || '|' ||
    has_table_privilege(
      '$CONNECTOR_DB_WRITER_USER','reporting.activities','INSERT'
    )::int || '|' ||
    has_function_privilege(
      '$CONNECTOR_DB_WRITER_USER',
      'ingestion.ingest_revenue_domain_record_v2(text,text,jsonb)','EXECUTE'
    )::int || '|' ||
    has_function_privilege(
      '$REPORTING_DB_READER_USER',
      'ingestion.ingest_revenue_domain_record_v2(text,text,jsonb)','EXECUTE'
    )::int;
")"
assert_eq "$privilege_state" "1|0|0|1|0" \
  "Revenue Question Pack least-privilege boundary"

writer_result="$(psql_writer -c "
  SELECT ingestion.ingest_revenue_domain_record_v2(
    'verify_qp_activity','writer-proof',
    '{\"sales_rep\":\"QP Alpha\",\"activity_type\":\"task\",\"due_at\":\"2026-09-20T17:00:00Z\",\"completed_at\":\"2026-09-20T16:00:00Z\"}'::jsonb
  )->>'status';
")"
assert_eq "$writer_result" "upserted" \
  "connector writer could not use bounded generic ingestion gateway"

reader_result="$(psql_reader -c "
  SELECT governance.execute_agent_report_request_v2(
    'verify-qpack-admin','open_pipeline','this_month','metric_report',
    '[]'::jsonb,'{\"lead_source\":\"QPVerify\"}'::jsonb,
    '2026-09-15T12:00:00Z'
  ) #>> '{current_period,value}';
")"
assert_eq "$reader_result" "3000.00" \
  "reporting reader could not execute bounded Revenue Question Pack gateway"

echo "PASS: 37 governed KPI contracts resolve across nine metric packs."
echo "PASS: deal, target, funnel, activity, subscription, and forecast facts calculate correctly."
echo "PASS: one-dimension breakdown and pipeline diagnostic reporting are governed and deterministic."
echo "PASS: own-scope RBAC restricts a sales rep to their canonical records."
echo "PASS: incomplete metric inputs and unready client domains fail closed as data unavailable."
echo "PASS: original four-KPI gateway and query templates remain backward compatible."
echo "PASS: connector writer can use bounded ingestion but cannot write reporting facts directly."
echo "PASS: Revenue Question Pack isolated verification passed."

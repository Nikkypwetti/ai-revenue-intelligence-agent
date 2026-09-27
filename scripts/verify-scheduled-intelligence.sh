#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  REPORTING_DB_ADMIN_USER REPORTING_DB_NAME
  REPORTING_DB_READER_USER REPORTING_DB_READER_PASSWORD
  AUDIT_DB_WRITER_USER AUDIT_DB_WRITER_PASSWORD
  N8N_DB_USER N8N_DB_NAME
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

psql_admin() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" "$@"
}

psql_reader() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T \
    -e PGPASSWORD="$REPORTING_DB_READER_PASSWORD" reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_READER_USER" -d "$REPORTING_DB_NAME" "$@"
}

psql_audit() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T \
    -e PGPASSWORD="$AUDIT_DB_WRITER_PASSWORD" reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$AUDIT_DB_WRITER_USER" -d "$REPORTING_DB_NAME" "$@"
}

psql_n8n() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$N8N_DB_USER" -d "$N8N_DB_NAME" "$@"
}

cleanup() {
  psql_admin -c "
    DELETE FROM audit.agent_events
    WHERE event_id LIKE 'SCHED-VERIFY-%';

    DELETE FROM reporting.deals
    WHERE connector_key='rest_ingestion_api'
      AND source_record_id LIKE 'sched-verify-%';
  " >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

rule_state="$(psql_admin -c "
  SELECT count(*) || '|' ||
         max((config->>'change_percent')::numeric)
           FILTER (WHERE rule_key='pipeline_value_change')
  FROM governance.intelligence_rule
  WHERE active;
")"
[[ "$rule_state" == "4|20" || "$rule_state" == "4|20.00" ]] || {
  echo "FAIL: scheduled-intelligence rules are missing or incorrectly configured."
  exit 1
}

workflow_state="$(psql_n8n -c "
  SELECT active::int || '|' ||
         (\"versionId\" = \"activeVersionId\")::int || '|' ||
         (
           SELECT count(*)
           FROM json_array_elements(nodes) n
           WHERE n->>'type'='n8n-nodes-base.scheduleTrigger'
         )
  FROM workflow_entity
  WHERE id='REVINTV2SCHEDULED01';
")"
[[ "$workflow_state" == "1|1|2" ]] || {
  echo "FAIL: scheduled-intelligence workflow is not active with two triggers."
  exit 1
}

schedule_state="$(psql_n8n -c "
  SELECT string_agg(
    (n->>'name') || ':' ||
    (n->'parameters'->'rule'->'interval'->0->>'field') || ':' ||
    COALESCE((n->'parameters'->'rule'->'interval'->0->>'triggerAtDay'),'') || ':' ||
    (n->'parameters'->'rule'->'interval'->0->>'triggerAtHour') || ':' ||
    (n->'parameters'->'rule'->'interval'->0->>'triggerAtMinute'),
    ',' ORDER BY n->>'name'
  )
  FROM workflow_entity w
  CROSS JOIN LATERAL json_array_elements(w.nodes) n
  WHERE w.id='REVINTV2SCHEDULED01'
    AND n->>'type'='n8n-nodes-base.scheduleTrigger';
")"
[[ "$schedule_state" == "INT | Daily Schedule:days::8:0,INT | Weekly Schedule:weeks:[1]:8:15" ]] || {
  echo "FAIL: daily/weekly trigger schedule is incorrect."
  exit 1
}

credential_state="$(psql_n8n -c "
  SELECT count(*) || '|' ||
         count(*) FILTER (WHERE data NOT LIKE '{%')
  FROM credentials_entity
  WHERE id IN ('REVINTPGREPORTRO001','REVINTPGAUDITWR001');
")"
[[ "$credential_state" == "2|2" ]] || {
  echo "FAIL: scheduled workflow database credentials are missing or not encrypted."
  exit 1
}

if ! ss -ltn | grep -qE '127\.0\.0\.1:5681|0\.0\.0\.0:5681|\[::\]:5681'; then
  echo "FAIL: Agent v2 is not listening on port 5681."
  exit 1
fi

if ! ss -ltn | grep -qE ':5678[[:space:]]'; then
  echo "FAIL: protected old local n8n listener on port 5678 is missing."
  exit 1
fi

health="$(curl -fsS --max-time 10 http://127.0.0.1:5681/healthz)"
[[ "$health" == *'"status":"ok"'* ]] || {
  echo "FAIL: Agent v2 health endpoint is not healthy."
  exit 1
}

psql_admin <<'SQL' >/dev/null
INSERT INTO reporting.deals (
  connector_key, source_record_id, deal_name, amount, currency_code,
  stage_name, stage_category, sales_rep, lead_source, created_at,
  expected_close_date, closed_at, source_updated_at,
  source_payload_hash, contract_version, ingested_at
)
SELECT
  'rest_ingestion_api',
  x.source_record_id,
  x.deal_name,
  x.amount,
  btrim(b.currency_code::text),
  x.stage_name,
  x.stage_category,
  x.sales_rep,
  'Verification',
  x.created_at,
  x.expected_close_date,
  x.closed_at,
  x.source_updated_at,
  md5(x.source_record_id),
  1,
  now()
FROM governance.business_config b
CROSS JOIN (
  VALUES
    (
      'sched-verify-stale',
      'Scheduled Verify Stale',
      900000000000.00::numeric,
      'Proposal',
      'open',
      'Verify Rep A',
      now() - interval '30 days',
      now() + interval '10 days',
      NULL::timestamptz,
      now() - interval '20 days'
    ),
    (
      'sched-verify-missing-close',
      'Scheduled Verify Missing Close',
      800000000000.00::numeric,
      'Discovery',
      'open',
      'Verify Rep B',
      now() - interval '2 days',
      NULL::timestamptz,
      NULL::timestamptz,
      now()
    ),
    (
      'sched-verify-won',
      'Scheduled Verify Won',
      700000000000.00::numeric,
      'Closed Won',
      'won',
      'Verify Rep C',
      now() - interval '10 days',
      now() - interval '2 days',
      now() - interval '2 days',
      now() - interval '2 days'
    )
) AS x(
  source_record_id, deal_name, amount, stage_name, stage_category,
  sales_rep, created_at, expected_close_date, closed_at, source_updated_at
)
LIMIT 3;

INSERT INTO audit.agent_events (
  event_id, event_type, stage, actor, payload, created_at
)
VALUES (
  'SCHED-VERIFY-PREV',
  'scheduled_intelligence_generated',
  'scheduled_intelligence',
  'n8n_scheduled_intelligence',
  jsonb_build_object(
    'cadence','daily',
    'as_of',(now() - interval '1 day'),
    'metrics',jsonb_build_object('open_pipeline_value',1)
  ),
  now() - interval '1 second'
);
SQL

digest_state="$(psql_admin -c "
  WITH d AS (
    SELECT governance.build_scheduled_intelligence('daily',now()) AS j
  )
  SELECT
    j->>'cadence' || '|' ||
    (j->'metrics'->>'stale_open_deals_count') || '|' ||
    (j->'metrics'->>'missing_expected_close_date_count') || '|' ||
    (j->'metrics'->>'closed_won_deals_last_7_days') || '|' ||
    (j->>'risk_count')
  FROM d;
")"
IFS='|' read -r cadence stale_count missing_count won_count risk_count <<< "$digest_state"
[[ "$cadence" == "daily" ]] || { echo "FAIL: digest cadence is not daily."; exit 1; }
[[ "$stale_count" -ge 1 ]] || { echo "FAIL: stale-open-deal risk was not detected."; exit 1; }
[[ "$missing_count" -ge 1 ]] || { echo "FAIL: missing-close-date risk was not detected."; exit 1; }
[[ "$won_count" -ge 1 ]] || { echo "FAIL: seven-day won context was not calculated."; exit 1; }
[[ "$risk_count" -ge 3 ]] || { echo "FAIL: expected stale, missing-close, and pipeline-change risks."; exit 1; }

risk_keys="$(psql_admin -c "
  SELECT string_agg(value->>'rule_key',',' ORDER BY value->>'rule_key')
  FROM jsonb_array_elements(
    governance.build_scheduled_intelligence('daily',now())->'risk_flags'
  ) value;
")"
[[ "$risk_keys" == *"missing_expected_close_date"* ]] || {
  echo "FAIL: missing-close-date rule is absent from digest."
  exit 1
}
[[ "$risk_keys" == *"pipeline_value_change"* ]] || {
  echo "FAIL: pipeline-value-change anomaly is absent from digest."
  exit 1
}
[[ "$risk_keys" == *"stale_open_deals"* ]] || {
  echo "FAIL: stale-open-deals rule is absent from digest."
  exit 1
}

stale_fixture_visible="$(psql_admin -c "
  SELECT count(*)
  FROM jsonb_array_elements(
    governance.build_scheduled_intelligence('daily',now())->'top_stale_deals'
  ) value
  WHERE value->>'source_record_id'='sched-verify-stale';
")"
[[ "$stale_fixture_visible" == "1" ]] || {
  echo "FAIL: highest-value stale fixture is missing from top stale deals."
  exit 1
}

permission_state="$(psql_admin -c "
  SELECT
    has_function_privilege(
      '$REPORTING_DB_READER_USER',
      'governance.build_scheduled_intelligence(text,timestamptz)',
      'EXECUTE'
    )::int || '|' ||
    has_table_privilege(
      '$REPORTING_DB_READER_USER',
      'governance.intelligence_rule',
      'SELECT'
    )::int || '|' ||
    has_table_privilege(
      '$REPORTING_DB_READER_USER',
      'governance.intelligence_rule',
      'INSERT'
    )::int || '|' ||
    has_table_privilege(
      '$REPORTING_DB_READER_USER',
      'audit.agent_events',
      'SELECT'
    )::int;
")"
[[ "$permission_state" == "1|1|0|0" ]] || {
  echo "FAIL: scheduled-intelligence reader privilege boundary is incorrect."
  exit 1
}

reader_state="$(psql_reader -c "
  SELECT (governance.build_scheduled_intelligence('weekly',now())->>'status');
")"
[[ "$reader_state" == "generated" ]] || {
  echo "FAIL: reporting reader cannot execute bounded scheduled intelligence."
  exit 1
}

psql_audit -c "
  INSERT INTO audit.agent_events (
    event_id,event_type,stage,actor,payload
  )
  VALUES (
    'SCHED-VERIFY-AUDIT',
    'scheduled_intelligence_generated',
    'scheduled_intelligence',
    'n8n_scheduled_intelligence',
    '{\"cadence\":\"verification\",\"status\":\"generated\"}'::jsonb
  );
" >/dev/null

audit_insert="$(psql_admin -c "
  SELECT count(*) FROM audit.agent_events
  WHERE event_id='SCHED-VERIFY-AUDIT';
")"
[[ "$audit_insert" == "1" ]] || {
  echo "FAIL: audit writer cannot persist scheduled-intelligence events."
  exit 1
}

if psql_admin -c "
  SELECT governance.build_scheduled_intelligence('hourly',now());
" >/dev/null 2>&1; then
  echo "FAIL: unsupported scheduled-intelligence cadence was accepted."
  exit 1
fi

echo "PASS: daily and weekly Schedule Trigger configuration is active."
echo "PASS: stale open deals and missing expected-close dates are detected."
echo "PASS: material pipeline movement is detected against the previous snapshot."
echo "PASS: seven-day closed-won context and top stale deals are generated."
echo "PASS: reporting reader can execute only the bounded intelligence function."
echo "PASS: audit writer can persist scheduled-intelligence events."
echo "PASS: old n8n port 5678 remains available and Agent v2 remains isolated on 5681."

bash "$ROOT_DIR/scripts/verify-agent-core.sh"

echo "PASS: scheduled-intelligence verification passed."

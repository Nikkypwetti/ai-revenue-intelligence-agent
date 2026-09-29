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
    WHERE event_id='REL-VERIFY-AUDIT';

    DELETE FROM audit.dead_letter
    WHERE component_key='reliability_verify';

    DELETE FROM audit.runtime_failures
    WHERE component_key='reliability_verify';

    DELETE FROM governance.circuit_state
    WHERE component_key='reliability_verify';

    DELETE FROM governance.reliability_policy
    WHERE component_key='reliability_verify';
  " >/dev/null
}
trap 'cleanup || true' EXIT
cleanup

policy_state="$(psql_admin -c "
  SELECT count(*) || '|' ||
         sum(max_attempts) || '|' ||
         min(retry_delay_ms)
  FROM governance.reliability_policy
  WHERE active
    AND component_key IN (
      'rest_ingestion',
      'agent_reporting',
      'scheduled_intelligence',
      'observability'
    );
")"
[[ "$policy_state" == "4|12|2000" ]] || {
  echo "FAIL: runtime reliability policies are missing or incorrectly configured."
  exit 1
}

workflow_state="$(psql_n8n -c "
  SELECT count(*) || '|' ||
         count(*) FILTER (
           WHERE active
             AND settings->>'errorWorkflow'='REVINTV2SYSERROR01'
         )
  FROM workflow_entity
  WHERE id IN (
    'REVINTV2RESTINGEST01',
    'REVINTV2AGENTCORE01',
    'REVINTV2SCHEDULED01',
    'REVINTV2OBS01'
  );
")"
[[ "$workflow_state" == "4|4" ]] || {
  echo "FAIL: protected workflows do not all reference the reliability error workflow."
  exit 1
}

error_workflow_state="$(psql_n8n -c "
  SELECT active::int || '|' ||
         (
           SELECT count(*)
           FROM json_array_elements(nodes) n
           WHERE n->>'type'='n8n-nodes-base.errorTrigger'
         ) || '|' ||
         (
           SELECT count(*)
           FROM json_array_elements(nodes) n
           WHERE n->>'name'='SYS | Record Failure + Dead Letter'
             AND coalesce((n->>'retryOnFail')::boolean,false)
             AND coalesce((n->>'maxTries')::integer,0)=3
         )
  FROM workflow_entity
  WHERE id='REVINTV2SYSERROR01';
")"
[[ "$error_workflow_state" == "1|1|1" ]] || {
  echo "FAIL: reliability error workflow is not active with the expected bounded logger."
  exit 1
}

retry_mismatch="$(psql_n8n -c "
  SELECT count(*)
  FROM workflow_entity w
  CROSS JOIN LATERAL json_array_elements(w.nodes) n
  WHERE w.id IN (
    'REVINTV2RESTINGEST01',
    'REVINTV2AGENTCORE01',
    'REVINTV2SCHEDULED01',
    'REVINTV2OBS01'
  )
    AND n->>'type'='n8n-nodes-base.postgres'
    AND NOT (
      coalesce((n->>'retryOnFail')::boolean,false)
      AND coalesce((n->>'maxTries')::integer,0)=3
      AND coalesce((n->>'waitBetweenTries')::integer,0)=2000
    );
")"
[[ "$retry_mismatch" == "0" ]] || {
  echo "FAIL: one or more safe PostgreSQL nodes lack the bounded retry policy."
  exit 1
}

audit_helper_count="$(psql_n8n -c "
  SELECT count(*)
  FROM workflow_entity w
  CROSS JOIN LATERAL json_array_elements(w.nodes) n
  WHERE w.id IN (
    'REVINTV2RESTINGEST01',
    'REVINTV2AGENTCORE01',
    'REVINTV2SCHEDULED01',
    'REVINTV2OBS01'
  )
    AND n->>'type'='n8n-nodes-base.postgres'
    AND n->>'name' LIKE 'AUD |%'
    AND (n->'parameters'->>'query') LIKE '%record_reliable_audit_event%';
")"
[[ "$audit_helper_count" == "5" ]] || {
  echo "FAIL: runtime audit nodes do not all use the conflict-safe audit helper."
  exit 1
}

scheduled_identity_state="$(psql_n8n -c "
  SELECT
    count(*) FILTER (
      WHERE n->>'name'='REP | Prepare Intelligence Event'
        AND (n->'parameters'->>'jsCode') LIKE '%status.toUpperCase()%'
    ) || '|' ||
    count(*) FILTER (
      WHERE n->>'name'='AUD | Record Scheduled Intelligence'
        AND (n->'parameters'->>'query') LIKE '%record_reliable_audit_event%'
        AND (n->'parameters'->'options'->>'queryReplacement') LIKE '%event_type%'
    )
  FROM workflow_entity w
  CROSS JOIN LATERAL json_array_elements(w.nodes) n
  WHERE w.id='REVINTV2SCHEDULED01';
")"
[[ "$scheduled_identity_state" == "1|1" ]] || {
  echo "FAIL: scheduled generated/skipped events do not have separate idempotent identities."
  exit 1
}

permission_state="$(psql_admin -c "
  SELECT
    has_function_privilege(
      '$REPORTING_DB_READER_USER',
      'governance.acquire_runtime_gate(text,timestamptz)',
      'EXECUTE'
    )::int || '|' ||
    has_table_privilege(
      '$REPORTING_DB_READER_USER',
      'governance.circuit_state',
      'UPDATE'
    )::int || '|' ||
    has_function_privilege(
      '$AUDIT_DB_WRITER_USER',
      'governance.record_terminal_failure(jsonb,timestamptz)',
      'EXECUTE'
    )::int || '|' ||
    has_function_privilege(
      '$AUDIT_DB_WRITER_USER',
      'governance.record_reliable_audit_event(text,text,text,text,text,text,jsonb,text,timestamptz)',
      'EXECUTE'
    )::int || '|' ||
    has_table_privilege(
      '$AUDIT_DB_WRITER_USER',
      'audit.runtime_failures',
      'SELECT'
    )::int || '|' ||
    has_table_privilege(
      '$AUDIT_DB_WRITER_USER',
      'audit.dead_letter',
      'UPDATE'
    )::int;
")"
[[ "$permission_state" == "1|0|1|1|0|0" ]] || {
  echo "FAIL: reliability privilege boundaries are incorrect."
  exit 1
}

class_state="$(psql_audit -c "
  SELECT
    (governance.classify_runtime_error(
      '{\"http_status\":429,\"error_message\":\"too many requests\"}'::jsonb
    )->>'error_type') || '|' ||
    (governance.classify_runtime_error(
      '{\"http_status\":429,\"error_message\":\"too many requests\"}'::jsonb
    )->>'retryable') || '|' ||
    (governance.classify_runtime_error(
      '{\"http_status\":403,\"error_message\":\"forbidden\"}'::jsonb
    )->>'error_type') || '|' ||
    (governance.classify_runtime_error(
      '{\"http_status\":403,\"error_message\":\"forbidden\"}'::jsonb
    )->>'retryable');
")"
[[ "$class_state" == "rate_limit|true|authentication_or_permission|false" ]] || {
  echo "FAIL: deterministic error classification is incorrect."
  exit 1
}

psql_admin -c "
  INSERT INTO governance.reliability_policy (
    component_key,workflow_id,display_name,
    max_attempts,retry_delay_ms,
    circuit_failure_threshold,circuit_open_seconds,
    half_open_probe_seconds,active
  )
  VALUES (
    'reliability_verify','VERIFY-WORKFLOW','Verification component',
    3,500,3,30,5,true
  );

  INSERT INTO governance.circuit_state(component_key)
  VALUES ('reliability_verify');
" >/dev/null

record_failure() {
  local execution_id="$1"
  psql_audit -c "
    SELECT governance.record_terminal_failure(
      jsonb_build_object(
        'component_key','reliability_verify',
        'workflow_id','VERIFY-WORKFLOW',
        'workflow_name','Verification Workflow',
        'execution_id','$execution_id',
        'node_name','DB | Verification',
        'error_name','TimeoutError',
        'error_code','ETIMEDOUT',
        'error_message','upstream request timed out',
        'http_status',504,
        'occurred_at',now()
      )
    )->>'status';
  "
}

[[ "$(record_failure verify-1)" == "recorded" ]] || {
  echo "FAIL: first terminal failure was not recorded."
  exit 1
}
[[ "$(record_failure verify-1)" == "duplicate_ignored" ]] || {
  echo "FAIL: duplicate terminal failure was not suppressed."
  exit 1
}
[[ "$(record_failure verify-2)" == "recorded" ]] || {
  echo "FAIL: second distinct terminal failure was not recorded."
  exit 1
}
[[ "$(record_failure verify-3)" == "recorded" ]] || {
  echo "FAIL: third distinct terminal failure was not recorded."
  exit 1
}

failure_state="$(psql_admin -c "
  SELECT
    (SELECT count(*) FROM audit.runtime_failures
      WHERE component_key='reliability_verify') || '|' ||
    (SELECT count(*) FROM audit.dead_letter
      WHERE component_key='reliability_verify') || '|' ||
    state || '|' || consecutive_failures
  FROM governance.circuit_state
  WHERE component_key='reliability_verify';
")"
[[ "$failure_state" == "3|3|open|3" ]] || {
  echo "FAIL: duplicate suppression, dead-lettering, or circuit opening is incorrect."
  exit 1
}

gate_open="$(psql_reader -c "
  SELECT
    (g->>'allowed') || '|' || (g->>'state')
  FROM (
    SELECT governance.acquire_runtime_gate('reliability_verify') AS g
  ) s;
")"
[[ "$gate_open" == "false|open" ]] || {
  echo "FAIL: open circuit did not block execution."
  exit 1
}

psql_admin -c "
  UPDATE governance.circuit_state
  SET reopen_after=now()-interval '1 second'
  WHERE component_key='reliability_verify';
" >/dev/null

gate_probe="$(psql_reader -c "
  SELECT
    (g->>'allowed') || '|' || (g->>'state') || '|' || (g->>'probe')
  FROM (
    SELECT governance.acquire_runtime_gate('reliability_verify') AS g
  ) s;
")"
[[ "$gate_probe" == "true|half_open|true" ]] || {
  echo "FAIL: expired circuit did not allow a half-open probe."
  exit 1
}

second_probe="$(psql_reader -c "
  SELECT
    (g->>'allowed') || '|' || (g->>'state')
  FROM (
    SELECT governance.acquire_runtime_gate('reliability_verify') AS g
  ) s;
")"
[[ "$second_probe" == "false|half_open" ]] || {
  echo "FAIL: half-open circuit allowed more than one active probe."
  exit 1
}

success_state="$(psql_audit -c "
  SELECT governance.record_runtime_success('reliability_verify')->>'state';
")"
[[ "$success_state" == "closed" ]] || {
  echo "FAIL: bounded success did not close the circuit."
  exit 1
}

closed_state="$(psql_admin -c "
  SELECT state || '|' || consecutive_failures
  FROM governance.circuit_state
  WHERE component_key='reliability_verify';
")"
[[ "$closed_state" == "closed|0" ]] || {
  echo "FAIL: circuit success reset is incomplete."
  exit 1
}

audit_first="$(psql_audit -c "
  SELECT governance.record_reliable_audit_event(
    'REL-VERIFY-AUDIT',
    NULL,NULL,
    'reliability_verification',
    'verification',
    'verification',
    '{\"status\":\"ok\"}'::jsonb,
    NULL
  )->>'audit_status';
")"
audit_second="$(psql_audit -c "
  SELECT governance.record_reliable_audit_event(
    'REL-VERIFY-AUDIT',
    NULL,NULL,
    'reliability_verification',
    'verification',
    'verification',
    '{\"status\":\"ok\"}'::jsonb,
    NULL
  )->>'audit_status';
")"
[[ "$audit_first" == "recorded" && "$audit_second" == "duplicate_ignored" ]] || {
  echo "FAIL: conflict-safe audit helper is not idempotent."
  exit 1
}

audit_count="$(psql_admin -c "
  SELECT count(*)
  FROM audit.agent_events
  WHERE event_id='REL-VERIFY-AUDIT';
")"
[[ "$audit_count" == "1" ]] || {
  echo "FAIL: idempotent audit helper created duplicate events."
  exit 1
}

bash "$ROOT_DIR/scripts/verify-runtime-isolation.sh"

echo "PASS: all protected PostgreSQL nodes use bounded three-attempt retries."
echo "PASS: terminal failures route to the active Agent v2 reliability workflow."
echo "PASS: failure classification distinguishes retryable and non-retryable errors."
echo "PASS: duplicate failures are suppressed before circuit counting."
echo "PASS: terminal failures create one dead-letter record per incident."
echo "PASS: three terminal failures open the circuit and block execution."
echo "PASS: expired circuits allow one half-open probe and block concurrent probes."
echo "PASS: bounded success closes the circuit and resets failure count."
echo "PASS: runtime audit writes are conflict-safe without broadening audit-writer table privileges."
echo "PASS: Agent v2 runtime isolation verification passed."

bash "$ROOT_DIR/scripts/verify-scheduled-intelligence.sh"

cleanup
trap - EXIT

echo "PASS: reliability-core verification passed."

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
    WHERE event_id='OBS-VERIFY-SNAPSHOT';

    DELETE FROM audit.agent_events
    WHERE event_type='runtime_health_snapshot'
      AND stage='observability'
      AND actor='n8n_observability'
      AND payload::text LIKE '%observability_verify%';

    DELETE FROM audit.dead_letter
    WHERE component_key='observability_verify';

    DELETE FROM audit.runtime_failures
    WHERE component_key='observability_verify';

    DELETE FROM governance.circuit_state
    WHERE component_key='observability_verify';

    DELETE FROM governance.reliability_policy
    WHERE component_key='observability_verify';
  " >/dev/null
}
trap 'cleanup || true' EXIT
cleanup

surface_state="$(psql_admin -c "
  SELECT
    (to_regclass('observability.component_status') IS NOT NULL)::int || '|' ||
    (to_regclass('observability.runtime_status') IS NOT NULL)::int || '|' ||
    (to_regclass('observability.alert_ready') IS NOT NULL)::int || '|' ||
    (to_regclass('observability.snapshot_history') IS NOT NULL)::int || '|' ||
    (to_regprocedure('observability.build_runtime_snapshot()') IS NOT NULL)::int;
")"
[[ "$surface_state" == "1|1|1|1|1" ]] || {
  echo "FAIL: one or more observability surfaces are missing."
  exit 1
}

policy_state="$(psql_admin -c "
  SELECT workflow_id || '|' || max_attempts || '|' || retry_delay_ms || '|' || active
  FROM governance.reliability_policy
  WHERE component_key='observability';
")"
[[ "$policy_state" == "REVINTV2OBS01|3|2000|true" ]] || {
  echo "FAIL: observability reliability policy is missing or incorrect."
  exit 1
}

workflow_state="$(psql_n8n -c "
  SELECT active::int || '|' ||
         coalesce(settings->>'errorWorkflow','') || '|' ||
         (
           SELECT count(*)
           FROM json_array_elements(nodes) n
           WHERE n->>'type'='n8n-nodes-base.scheduleTrigger'
             AND n->'parameters'->'rule'->'interval'->0->>'field'='minutes'
             AND (n->'parameters'->'rule'->'interval'->0->>'minutesInterval')::int=5
         ) || '|' ||
         (
           SELECT count(*)
           FROM json_array_elements(nodes) n
           WHERE n->>'type'='n8n-nodes-base.postgres'
             AND coalesce((n->>'retryOnFail')::boolean,false)
             AND coalesce((n->>'maxTries')::integer,0)=3
             AND coalesce((n->>'waitBetweenTries')::integer,0)=2000
         )
  FROM workflow_entity
  WHERE id='REVINTV2OBS01';
")"
[[ "$workflow_state" == "1|REVINTV2SYSERROR01|1|2" ]] || {
  echo "FAIL: observability workflow is not active with the five-minute schedule and bounded retries."
  exit 1
}

handler_mapping="$(psql_n8n -c "
  SELECT count(*)
  FROM workflow_entity w
  CROSS JOIN LATERAL json_array_elements(w.nodes) n
  WHERE w.id='REVINTV2SYSERROR01'
    AND n->>'name'='SYS | Normalize Terminal Failure'
    AND (n->'parameters'->>'jsCode') LIKE '%REVINTV2OBS01%'
    AND (n->'parameters'->>'jsCode') LIKE '%observability%';
")"
[[ "$handler_mapping" == "1" ]] || {
  echo "FAIL: reliability handler does not map observability failures."
  exit 1
}

permission_state="$(psql_admin -c "
  SELECT
    has_schema_privilege('$REPORTING_DB_READER_USER','observability','USAGE')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','observability.component_status','SELECT')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','observability.runtime_status','SELECT')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','observability.alert_ready','SELECT')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','observability.snapshot_history','SELECT')::int || '|' ||
    has_function_privilege('$REPORTING_DB_READER_USER','observability.build_runtime_snapshot()','EXECUTE')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','audit.runtime_failures','SELECT')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','audit.dead_letter','SELECT')::int;
")"
[[ "$permission_state" == "1|1|1|1|1|1|0|0" ]] || {
  echo "FAIL: observability read boundary is incorrect."
  exit 1
}

baseline="$(psql_reader -c "
  SELECT
    overall_status || '|' ||
    component_count || '|' ||
    failures_1h || '|' ||
    open_dead_letters
  FROM observability.runtime_status;
")"
IFS='|' read -r baseline_status baseline_components baseline_failures baseline_dlq <<< "$baseline"
[[ "$baseline_components" == "4" ]] || {
  echo "FAIL: runtime status does not expose the four managed components."
  exit 1
}
[[ "$baseline_status" =~ ^(healthy|degraded|blocked|unknown)$ ]] || {
  echo "FAIL: runtime status returned an invalid status."
  exit 1
}

snapshot_baseline="$(psql_reader -c "
  SELECT
    (s->>'status') || '|' ||
    (s->>'overall_status') || '|' ||
    jsonb_array_length(s->'components')
  FROM (SELECT observability.build_runtime_snapshot() AS s) q;
")"
IFS='|' read -r snapshot_status snapshot_overall snapshot_components <<< "$snapshot_baseline"
[[ "$snapshot_status" == "generated" && "$snapshot_components" == "4" ]] || {
  echo "FAIL: bounded runtime snapshot is incomplete."
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
    'observability_verify','OBS-VERIFY-WF','Observability verification',
    3,500,3,30,5,true
  );

  INSERT INTO governance.circuit_state(component_key)
  VALUES ('observability_verify');
" >/dev/null

record_failure() {
  local execution_id="$1"
  psql_audit -c "
    SELECT governance.record_terminal_failure(
      jsonb_build_object(
        'component_key','observability_verify',
        'workflow_id','OBS-VERIFY-WF',
        'workflow_name','Observability Verification',
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

[[ "$(record_failure obs-verify-1)" == "recorded" ]] || {
  echo "FAIL: observability verification failure was not recorded."
  exit 1
}

degraded_state="$(psql_reader -c "
  SELECT operational_status || '|' || failures_1h || '|' || open_dead_letters
  FROM observability.component_status
  WHERE component_key='observability_verify';
")"
[[ "$degraded_state" == "degraded|1|1" ]] || {
  echo "FAIL: component status did not become degraded after a terminal failure."
  exit 1
}

alert_state="$(psql_reader -c "
  SELECT count(*) || '|' ||
         count(*) FILTER (WHERE alert_type='dead_letter_backlog') || '|' ||
         count(*) FILTER (WHERE alert_type='recent_terminal_failures')
  FROM observability.alert_ready
  WHERE component_key='observability_verify';
")"
[[ "$alert_state" == "2|1|1" ]] || {
  echo "FAIL: degraded component did not emit alert-ready failure and dead-letter rows."
  exit 1
}

[[ "$(record_failure obs-verify-2)" == "recorded" ]] || exit 1
[[ "$(record_failure obs-verify-3)" == "recorded" ]] || exit 1

blocked_state="$(psql_reader -c "
  SELECT operational_status || '|' || circuit_state || '|' || failures_1h || '|' || open_dead_letters
  FROM observability.component_status
  WHERE component_key='observability_verify';
")"
[[ "$blocked_state" == "blocked|open|3|3" ]] || {
  echo "FAIL: component status did not become blocked after the circuit opened."
  exit 1
}

circuit_alert="$(psql_reader -c "
  SELECT count(*)
  FROM observability.alert_ready
  WHERE component_key='observability_verify'
    AND alert_type='circuit_blocked'
    AND severity='critical';
")"
[[ "$circuit_alert" == "1" ]] || {
  echo "FAIL: open circuit did not emit a critical alert-ready row."
  exit 1
}

blocked_snapshot="$(psql_reader -c "
  SELECT
    (s->>'overall_status') || '|' ||
    jsonb_array_length(s->'components') || '|' ||
    jsonb_array_length(s->'alerts')
  FROM (SELECT observability.build_runtime_snapshot() AS s) q;
")"
IFS='|' read -r blocked_overall blocked_components blocked_alerts <<< "$blocked_snapshot"
[[ "$blocked_overall" == "blocked" && "$blocked_components" == "5" && "$blocked_alerts" -ge 3 ]] || {
  echo "FAIL: runtime snapshot did not surface the blocked verification component."
  exit 1
}

success_state="$(psql_audit -c "
  SELECT governance.record_runtime_success('observability_verify')->>'state';
")"
[[ "$success_state" == "closed" ]] || {
  echo "FAIL: verification component did not close after bounded success."
  exit 1
}

post_success="$(psql_reader -c "
  SELECT operational_status || '|' || circuit_state
  FROM observability.component_status
  WHERE component_key='observability_verify';
")"
[[ "$post_success" == "degraded|closed" ]] || {
  echo "FAIL: unresolved dead-letter backlog is not preserved after circuit recovery."
  exit 1
}

snapshot_write="$(psql_audit -c "
  SELECT governance.record_reliable_audit_event(
    'OBS-VERIFY-SNAPSHOT',
    NULL,NULL,
    'runtime_health_snapshot',
    'observability',
    'n8n_observability',
    jsonb_build_object(
      'overall_status','healthy',
      'summary',jsonb_build_object('component_count',4),
      'alerts','[]'::jsonb
    ),
    'observability'
  )->>'audit_status';
")"
[[ "$snapshot_write" == "recorded" ]] || {
  echo "FAIL: Audit Writer could not persist a bounded observability snapshot."
  exit 1
}

history_state="$(psql_reader -c "
  SELECT count(*) || '|' || min(overall_status) || '|' || min(component_count)
  FROM observability.snapshot_history
  WHERE snapshot_id='OBS-VERIFY-SNAPSHOT';
")"
[[ "$history_state" == "1|healthy|4" ]] || {
  echo "FAIL: snapshot history did not expose the persisted verification snapshot."
  exit 1
}

bash "$ROOT_DIR/scripts/verify-runtime-isolation.sh"

echo "PASS: component and overall runtime status surfaces are available."
echo "PASS: reporting reader sees observability views without raw audit-table access."
echo "PASS: five-minute observability workflow is active with bounded retries."
echo "PASS: terminal failures drive deterministic degraded/blocked component status."
echo "PASS: circuit, failure, and dead-letter conditions emit alert-ready rows."
echo "PASS: runtime snapshot JSON includes component state and active alerts."
echo "PASS: snapshot history is persisted through the existing Audit Writer boundary."
echo "PASS: Agent v2 runtime isolation verification passed."

bash "$ROOT_DIR/scripts/verify-reliability-core.sh"

echo "PASS: observability-core verification passed."

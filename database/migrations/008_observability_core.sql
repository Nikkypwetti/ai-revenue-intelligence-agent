\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS observability;
REVOKE ALL ON SCHEMA observability FROM PUBLIC;

CREATE INDEX IF NOT EXISTS idx_runtime_failures_component_created
  ON audit.runtime_failures (component_key, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_dead_letter_status_component_created
  ON audit.dead_letter (dead_letter_status, component_key, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_agent_events_type_created
  ON audit.agent_events (event_type, created_at DESC);

CREATE OR REPLACE VIEW observability.component_status AS
WITH failure_rollup AS (
  SELECT
    component_key,
    count(*) FILTER (WHERE created_at >= now() - interval '1 hour') AS failures_1h,
    count(*) FILTER (WHERE created_at >= now() - interval '24 hours') AS failures_24h,
    max(created_at) AS latest_failure_at
  FROM audit.runtime_failures
  GROUP BY component_key
),
dead_letter_rollup AS (
  SELECT
    component_key,
    count(*) FILTER (WHERE dead_letter_status = 'open') AS open_dead_letters,
    min(created_at) FILTER (WHERE dead_letter_status = 'open') AS oldest_open_dead_letter_at
  FROM audit.dead_letter
  GROUP BY component_key
),
success_rollup AS (
  SELECT
    CASE event_type
      WHEN 'deal_ingested' THEN 'rest_ingestion'
      WHEN 'report_completed' THEN 'agent_reporting'
      WHEN 'scheduled_intelligence_generated' THEN 'scheduled_intelligence'
      WHEN 'runtime_health_snapshot' THEN 'observability'
      ELSE NULL
    END AS component_key,
    count(*) FILTER (WHERE created_at >= now() - interval '24 hours') AS success_events_24h,
    max(created_at) AS latest_success_event_at
  FROM audit.agent_events
  WHERE event_type IN (
    'deal_ingested',
    'report_completed',
    'scheduled_intelligence_generated',
    'runtime_health_snapshot'
  )
  GROUP BY 1
)
SELECT
  rp.component_key,
  rp.workflow_id,
  rp.display_name,
  coalesce(cs.state, 'closed') AS circuit_state,
  coalesce(cs.consecutive_failures, 0) AS consecutive_failures,
  cs.opened_at,
  cs.reopen_after,
  cs.probe_started_at,
  greatest(cs.last_success_at, sr.latest_success_event_at) AS last_success_at,
  greatest(cs.last_failure_at, fr.latest_failure_at) AS last_failure_at,
  cs.last_error_type,
  coalesce(sr.success_events_24h, 0)::bigint AS success_events_24h,
  coalesce(fr.failures_1h, 0)::bigint AS failures_1h,
  coalesce(fr.failures_24h, 0)::bigint AS failures_24h,
  coalesce(dl.open_dead_letters, 0)::bigint AS open_dead_letters,
  dl.oldest_open_dead_letter_at,
  CASE
    WHEN coalesce(cs.state, 'closed') IN ('open','half_open') THEN 'blocked'
    WHEN coalesce(dl.open_dead_letters, 0) > 0
      OR coalesce(fr.failures_1h, 0) > 0 THEN 'degraded'
    WHEN greatest(cs.last_success_at, sr.latest_success_event_at) IS NULL
      AND greatest(cs.last_failure_at, fr.latest_failure_at) IS NULL THEN 'unknown'
    ELSE 'healthy'
  END AS operational_status
FROM governance.reliability_policy rp
LEFT JOIN governance.circuit_state cs
  ON cs.component_key = rp.component_key
LEFT JOIN failure_rollup fr
  ON fr.component_key = rp.component_key
LEFT JOIN dead_letter_rollup dl
  ON dl.component_key = rp.component_key
LEFT JOIN success_rollup sr
  ON sr.component_key = rp.component_key
WHERE rp.active;

CREATE OR REPLACE VIEW observability.runtime_status AS
SELECT
  now() AS observed_at,
  CASE
    WHEN count(*) FILTER (WHERE operational_status = 'blocked') > 0 THEN 'blocked'
    WHEN count(*) FILTER (WHERE operational_status = 'degraded') > 0 THEN 'degraded'
    WHEN count(*) FILTER (WHERE operational_status = 'unknown') > 0 THEN 'unknown'
    ELSE 'healthy'
  END AS overall_status,
  count(*)::bigint AS component_count,
  count(*) FILTER (WHERE operational_status = 'healthy')::bigint AS healthy_components,
  count(*) FILTER (WHERE operational_status = 'degraded')::bigint AS degraded_components,
  count(*) FILTER (WHERE operational_status = 'blocked')::bigint AS blocked_components,
  count(*) FILTER (WHERE operational_status = 'unknown')::bigint AS unknown_components,
  coalesce(sum(failures_1h),0)::bigint AS failures_1h,
  coalesce(sum(failures_24h),0)::bigint AS failures_24h,
  coalesce(sum(open_dead_letters),0)::bigint AS open_dead_letters
FROM observability.component_status;

CREATE OR REPLACE VIEW observability.alert_ready AS
SELECT
  component_key,
  component_key || ':circuit:' || circuit_state AS alert_key,
  'critical'::text AS severity,
  'circuit_blocked'::text AS alert_type,
  display_name || ' circuit is ' || circuit_state AS summary,
  coalesce(opened_at, probe_started_at, last_failure_at) AS first_observed_at,
  jsonb_build_object(
    'circuit_state', circuit_state,
    'consecutive_failures', consecutive_failures,
    'retry_after', reopen_after
  ) AS context
FROM observability.component_status
WHERE operational_status = 'blocked'

UNION ALL

SELECT
  component_key,
  component_key || ':dead_letter_backlog',
  CASE WHEN open_dead_letters >= 3 THEN 'critical' ELSE 'warning' END,
  'dead_letter_backlog',
  display_name || ' has ' || open_dead_letters || ' open dead-letter item(s)',
  oldest_open_dead_letter_at,
  jsonb_build_object('open_dead_letters', open_dead_letters)
FROM observability.component_status
WHERE open_dead_letters > 0

UNION ALL

SELECT
  component_key,
  component_key || ':recent_terminal_failures',
  CASE WHEN failures_1h >= 3 THEN 'critical' ELSE 'warning' END,
  'recent_terminal_failures',
  display_name || ' recorded ' || failures_1h || ' terminal failure(s) in the last hour',
  last_failure_at,
  jsonb_build_object(
    'failures_1h', failures_1h,
    'failures_24h', failures_24h,
    'last_error_type', last_error_type
  )
FROM observability.component_status
WHERE failures_1h > 0;

CREATE OR REPLACE VIEW observability.snapshot_history AS
SELECT
  event_id AS snapshot_id,
  created_at,
  payload->>'overall_status' AS overall_status,
  coalesce((payload->'summary'->>'component_count')::integer,0) AS component_count,
  coalesce(jsonb_array_length(coalesce(payload->'alerts','[]'::jsonb)),0) AS alert_count,
  payload AS snapshot
FROM audit.agent_events
WHERE event_type = 'runtime_health_snapshot'
  AND stage = 'observability'
  AND actor = 'n8n_observability';

CREATE OR REPLACE FUNCTION observability.build_runtime_snapshot()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, observability, governance, audit
AS $$
  SELECT jsonb_build_object(
    'status','generated',
    'snapshot_version','1.0',
    'generated_at',now(),
    'overall_status',rs.overall_status,
    'summary',jsonb_build_object(
      'component_count',rs.component_count,
      'healthy_components',rs.healthy_components,
      'degraded_components',rs.degraded_components,
      'blocked_components',rs.blocked_components,
      'unknown_components',rs.unknown_components,
      'failures_1h',rs.failures_1h,
      'failures_24h',rs.failures_24h,
      'open_dead_letters',rs.open_dead_letters
    ),
    'components',coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'component_key',cs.component_key,
          'display_name',cs.display_name,
          'operational_status',cs.operational_status,
          'circuit_state',cs.circuit_state,
          'consecutive_failures',cs.consecutive_failures,
          'success_events_24h',cs.success_events_24h,
          'failures_1h',cs.failures_1h,
          'failures_24h',cs.failures_24h,
          'open_dead_letters',cs.open_dead_letters,
          'last_success_at',cs.last_success_at,
          'last_failure_at',cs.last_failure_at,
          'last_error_type',cs.last_error_type,
          'retry_after',cs.reopen_after
        )
        ORDER BY cs.component_key
      )
      FROM observability.component_status cs
    ),'[]'::jsonb),
    'alerts',coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'alert_key',a.alert_key,
          'component_key',a.component_key,
          'severity',a.severity,
          'alert_type',a.alert_type,
          'summary',a.summary,
          'first_observed_at',a.first_observed_at,
          'context',a.context
        )
        ORDER BY
          CASE a.severity WHEN 'critical' THEN 1 ELSE 2 END,
          a.component_key,
          a.alert_type
      )
      FROM observability.alert_ready a
    ),'[]'::jsonb)
  )
  FROM observability.runtime_status rs;
$$;

REVOKE ALL ON FUNCTION observability.build_runtime_snapshot() FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA observability FROM PUBLIC;

GRANT USAGE ON SCHEMA observability TO revint_governance_ro;
GRANT SELECT ON
  observability.component_status,
  observability.runtime_status,
  observability.alert_ready,
  observability.snapshot_history
TO revint_governance_ro;

GRANT EXECUTE ON FUNCTION observability.build_runtime_snapshot()
TO revint_governance_ro;

\set ON_ERROR_STOP on

INSERT INTO governance.reliability_policy (
  component_key, workflow_id, display_name,
  max_attempts, retry_delay_ms,
  circuit_failure_threshold, circuit_open_seconds,
  half_open_probe_seconds, active
)
VALUES
  (
    'rest_ingestion',
    'REVINTV2RESTINGEST01',
    'Authenticated REST deal ingestion',
    3, 2000, 3, 300, 60, true
  ),
  (
    'agent_reporting',
    'REVINTV2AGENTCORE01',
    'Governed report Agent execution',
    3, 2000, 3, 300, 60, true
  ),
  (
    'scheduled_intelligence',
    'REVINTV2SCHEDULED01',
    'Scheduled pipeline intelligence',
    3, 2000, 3, 600, 60, true
  )
ON CONFLICT (component_key) DO UPDATE SET
  workflow_id = EXCLUDED.workflow_id,
  display_name = EXCLUDED.display_name,
  max_attempts = EXCLUDED.max_attempts,
  retry_delay_ms = EXCLUDED.retry_delay_ms,
  circuit_failure_threshold = EXCLUDED.circuit_failure_threshold,
  circuit_open_seconds = EXCLUDED.circuit_open_seconds,
  half_open_probe_seconds = EXCLUDED.half_open_probe_seconds,
  active = EXCLUDED.active,
  updated_at = now();

INSERT INTO governance.circuit_state (component_key)
SELECT component_key
FROM governance.reliability_policy
WHERE active
ON CONFLICT (component_key) DO NOTHING;

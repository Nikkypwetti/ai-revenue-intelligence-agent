\set ON_ERROR_STOP on

INSERT INTO governance.reliability_policy (
  component_key, workflow_id, display_name,
  max_attempts, retry_delay_ms,
  circuit_failure_threshold, circuit_open_seconds,
  half_open_probe_seconds, active
)
VALUES (
  'email_delivery',
  'REVINTV2EMAIL01',
  'Governed Gmail report delivery',
  2, 2000, 3, 600, 60, true
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

INSERT INTO governance.circuit_state(component_key)
VALUES ('email_delivery')
ON CONFLICT (component_key) DO NOTHING;

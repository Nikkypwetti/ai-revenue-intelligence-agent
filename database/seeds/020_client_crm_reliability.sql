\set ON_ERROR_STOP on

INSERT INTO governance.reliability_policy (
  component_key, workflow_id, display_name,
  max_attempts, retry_delay_ms,
  circuit_failure_threshold, circuit_open_seconds,
  half_open_probe_seconds, active
)
VALUES
(
  'salesforce_sync',
  'REVINTV2SALESFORCE01',
  'Salesforce opportunity synchronization',
  3, 2000, 3, 600, 60, false
),
(
  'airtable_sync',
  'REVINTV2AIRTABLE01',
  'Airtable lead/funnel synchronization',
  3, 2000, 3, 600, 60, false
)
ON CONFLICT (component_key) DO UPDATE SET
  workflow_id = EXCLUDED.workflow_id,
  display_name = EXCLUDED.display_name,
  max_attempts = EXCLUDED.max_attempts,
  retry_delay_ms = EXCLUDED.retry_delay_ms,
  circuit_failure_threshold = EXCLUDED.circuit_failure_threshold,
  circuit_open_seconds = EXCLUDED.circuit_open_seconds,
  half_open_probe_seconds = EXCLUDED.half_open_probe_seconds,
  active = governance.reliability_policy.active,
  updated_at = now();

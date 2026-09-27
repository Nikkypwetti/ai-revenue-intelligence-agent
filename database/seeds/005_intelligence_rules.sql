\set ON_ERROR_STOP on

INSERT INTO governance.intelligence_rule (
  rule_key,
  display_name,
  description,
  rule_type,
  severity,
  config,
  active
)
VALUES
  (
    'stale_open_deals',
    'Stale Open Deals',
    'Flags open deals whose latest available source update exceeds the configured stale-deal threshold.',
    'risk',
    'warning',
    '{"threshold_source":"business_config.stale_deal_days"}'::jsonb,
    true
  ),
  (
    'missing_expected_close_date',
    'Missing Expected Close Date',
    'Flags open deals that cannot participate in expected-close-period pipeline reporting.',
    'risk',
    'warning',
    '{}'::jsonb,
    true
  ),
  (
    'pipeline_value_change',
    'Pipeline Value Change',
    'Flags material movement in total open pipeline value versus the previous snapshot of the same cadence.',
    'anomaly',
    'warning',
    '{"change_percent":20}'::jsonb,
    true
  ),
  (
    'scheduled_pipeline_digest',
    'Scheduled Pipeline Digest',
    'Generates the governed daily or weekly pipeline-risk digest.',
    'digest',
    'info',
    '{}'::jsonb,
    true
  )
ON CONFLICT (rule_key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  description = EXCLUDED.description,
  rule_type = EXCLUDED.rule_type,
  severity = EXCLUDED.severity,
  config = EXCLUDED.config,
  active = EXCLUDED.active,
  updated_at = now();

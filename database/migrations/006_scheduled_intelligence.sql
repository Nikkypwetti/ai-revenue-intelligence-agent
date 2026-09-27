\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS governance.intelligence_rule (
  rule_key text PRIMARY KEY,
  display_name text NOT NULL,
  description text NOT NULL,
  rule_type text NOT NULL CHECK (
    rule_type IN ('risk','anomaly','digest')
  ),
  severity text NOT NULL CHECK (
    severity IN ('info','warning','high')
  ),
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_typeof(config) = 'object')
);

CREATE OR REPLACE FUNCTION governance.build_scheduled_intelligence(
  p_cadence text,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, governance, reporting, audit
AS $$
DECLARE
  v_config governance.business_config%ROWTYPE;
  v_stale_days integer;
  v_change_threshold numeric(8,2) := 20.00;

  v_open_count bigint := 0;
  v_open_value numeric(18,2) := 0;
  v_stale_count bigint := 0;
  v_stale_value numeric(18,2) := 0;
  v_missing_close_count bigint := 0;
  v_missing_close_value numeric(18,2) := 0;
  v_won_7d_count bigint := 0;
  v_won_7d_value numeric(18,2) := 0;

  v_top_stale jsonb := '[]'::jsonb;
  v_previous jsonb;
  v_previous_value numeric(18,2);
  v_change_pct numeric;
  v_risks jsonb := '[]'::jsonb;
  v_previous_summary jsonb := NULL;
BEGIN
  IF p_cadence NOT IN ('daily','weekly') THEN
    RAISE EXCEPTION 'SCHEDULED_INTELLIGENCE_CADENCE_INVALID';
  END IF;

  SELECT *
  INTO v_config
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'BUSINESS_CONFIG_REQUIRED';
  END IF;

  v_stale_days := v_config.stale_deal_days;

  SELECT COALESCE((config->>'change_percent')::numeric, 20.00)
  INTO v_change_threshold
  FROM governance.intelligence_rule
  WHERE rule_key = 'pipeline_value_change'
    AND active;

  v_change_threshold := COALESCE(v_change_threshold, 20.00);

  SELECT
    count(*) FILTER (WHERE stage_category = 'open'),
    COALESCE(sum(amount) FILTER (WHERE stage_category = 'open'), 0)::numeric(18,2),
    count(*) FILTER (
      WHERE stage_category = 'open'
        AND COALESCE(source_updated_at, created_at, ingested_at)
            < p_as_of - make_interval(days => v_stale_days)
    ),
    COALESCE(sum(amount) FILTER (
      WHERE stage_category = 'open'
        AND COALESCE(source_updated_at, created_at, ingested_at)
            < p_as_of - make_interval(days => v_stale_days)
    ), 0)::numeric(18,2),
    count(*) FILTER (
      WHERE stage_category = 'open'
        AND expected_close_date IS NULL
    ),
    COALESCE(sum(amount) FILTER (
      WHERE stage_category = 'open'
        AND expected_close_date IS NULL
    ), 0)::numeric(18,2),
    count(*) FILTER (
      WHERE stage_category = 'won'
        AND closed_at >= p_as_of - interval '7 days'
        AND closed_at < p_as_of
    ),
    COALESCE(sum(amount) FILTER (
      WHERE stage_category = 'won'
        AND closed_at >= p_as_of - interval '7 days'
        AND closed_at < p_as_of
    ), 0)::numeric(18,2)
  INTO
    v_open_count,
    v_open_value,
    v_stale_count,
    v_stale_value,
    v_missing_close_count,
    v_missing_close_value,
    v_won_7d_count,
    v_won_7d_value
  FROM reporting.deals;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'source_record_id', source_record_id,
        'deal_name', deal_name,
        'amount', amount,
        'sales_rep', sales_rep,
        'expected_close_date', expected_close_date,
        'last_source_update',
          COALESCE(source_updated_at, created_at, ingested_at)
      )
      ORDER BY amount DESC, source_record_id
    ),
    '[]'::jsonb
  )
  INTO v_top_stale
  FROM (
    SELECT
      source_record_id,
      deal_name,
      amount,
      sales_rep,
      expected_close_date,
      source_updated_at,
      created_at,
      ingested_at
    FROM reporting.deals
    WHERE stage_category = 'open'
      AND COALESCE(source_updated_at, created_at, ingested_at)
          < p_as_of - make_interval(days => v_stale_days)
    ORDER BY amount DESC, source_record_id
    LIMIT 5
  ) s;

  SELECT payload
  INTO v_previous
  FROM audit.agent_events
  WHERE event_type = 'scheduled_intelligence_generated'
    AND actor = 'n8n_scheduled_intelligence'
    AND payload->>'cadence' = p_cadence
    AND created_at < p_as_of
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_previous IS NOT NULL
     AND COALESCE(v_previous #>> '{metrics,open_pipeline_value}', '')
         ~ '^[0-9]+(\.[0-9]+)?$' THEN
    v_previous_value :=
      (v_previous #>> '{metrics,open_pipeline_value}')::numeric;

    IF v_previous_value > 0 THEN
      v_change_pct := round(
        ((v_open_value - v_previous_value) / v_previous_value) * 100.0,
        2
      );
    END IF;

    v_previous_summary := jsonb_build_object(
      'as_of', v_previous->>'as_of',
      'open_pipeline_value', v_previous_value,
      'change_percent', v_change_pct
    );
  END IF;

  IF v_stale_count > 0
     AND EXISTS (
       SELECT 1 FROM governance.intelligence_rule
       WHERE rule_key='stale_open_deals' AND active
     ) THEN
    v_risks := v_risks || jsonb_build_array(
      jsonb_build_object(
        'rule_key','stale_open_deals',
        'severity','warning',
        'count',v_stale_count,
        'value',v_stale_value,
        'threshold_days',v_stale_days,
        'message',format(
          '%s open deal(s) have not received a source-system update within %s days.',
          v_stale_count, v_stale_days
        ),
        'recommended_action',
          'Review the highest-value stale open deals and confirm their current status.'
      )
    );
  END IF;

  IF v_missing_close_count > 0
     AND EXISTS (
       SELECT 1 FROM governance.intelligence_rule
       WHERE rule_key='missing_expected_close_date' AND active
     ) THEN
    v_risks := v_risks || jsonb_build_array(
      jsonb_build_object(
        'rule_key','missing_expected_close_date',
        'severity','warning',
        'count',v_missing_close_count,
        'value',v_missing_close_value,
        'message',format(
          '%s open deal(s) are missing an expected close date.',
          v_missing_close_count
        ),
        'recommended_action',
          'Complete expected close dates before relying on period-based pipeline reporting.'
      )
    );
  END IF;

  IF v_change_pct IS NOT NULL
     AND abs(v_change_pct) >= v_change_threshold
     AND EXISTS (
       SELECT 1 FROM governance.intelligence_rule
       WHERE rule_key='pipeline_value_change' AND active
     ) THEN
    v_risks := v_risks || jsonb_build_array(
      jsonb_build_object(
        'rule_key','pipeline_value_change',
        'severity','warning',
        'change_percent',v_change_pct,
        'threshold_percent',v_change_threshold,
        'direction',CASE
          WHEN v_change_pct > 0 THEN 'increase'
          WHEN v_change_pct < 0 THEN 'decrease'
          ELSE 'unchanged'
        END,
        'message',format(
          'Open pipeline value moved %s%% versus the previous %s snapshot.',
          v_change_pct, p_cadence
        ),
        'recommended_action',
          'Review the deals responsible for the material pipeline movement.'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'status','generated',
    'cadence',p_cadence,
    'as_of',p_as_of,
    'company_name',v_config.company_name,
    'timezone',v_config.timezone,
    'currency_code',btrim(v_config.currency_code::text),
    'rules_version',1,
    'metrics',jsonb_build_object(
      'open_deals_count',v_open_count,
      'open_pipeline_value',v_open_value,
      'stale_open_deals_count',v_stale_count,
      'stale_open_deals_value',v_stale_value,
      'missing_expected_close_date_count',v_missing_close_count,
      'missing_expected_close_date_value',v_missing_close_value,
      'closed_won_deals_last_7_days',v_won_7d_count,
      'closed_won_revenue_last_7_days',v_won_7d_value
    ),
    'risk_count',jsonb_array_length(v_risks),
    'risk_flags',v_risks,
    'top_stale_deals',v_top_stale,
    'previous_snapshot',v_previous_summary,
    'limitations',jsonb_build_array(
      'Staleness uses source_updated_at with created_at/ingested_at fallback; it is not a CRM activity timestamp.',
      'Pipeline coverage is not calculated because no governed revenue target or quota fact is present in the canonical model.'
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION governance.build_scheduled_intelligence(text,timestamptz)
FROM PUBLIC;

-- The SECURITY DEFINER owner needs bounded history access for previous-snapshot comparison.
-- This grant is made to the migration/admin role executing this file, not to the runtime reader.
GRANT SELECT ON audit.agent_events TO CURRENT_USER;

GRANT SELECT ON governance.intelligence_rule
TO revint_governance_ro;

GRANT EXECUTE ON FUNCTION
  governance.build_scheduled_intelligence(text,timestamptz)
TO revint_governance_ro;

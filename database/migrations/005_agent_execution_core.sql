\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION governance.resolve_relative_period(
  p_period_key text,
  p_reference timestamptz DEFAULT now()
)
RETURNS TABLE (
  period_key text,
  start_at timestamptz,
  end_at timestamptz,
  previous_start_at timestamptz,
  previous_end_at timestamptz,
  reporting_timezone text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
DECLARE
  v_timezone text;
  v_local_reference timestamp;
  v_start_local timestamp;
  v_end_local timestamp;
  v_previous_start_local timestamp;
  v_previous_end_local timestamp;
BEGIN
  SELECT timezone
  INTO v_timezone
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;

  IF NULLIF(btrim(COALESCE(v_timezone, '')), '') IS NULL THEN
    RAISE EXCEPTION 'BUSINESS_TIMEZONE_NOT_CONFIGURED';
  END IF;

  IF p_period_key NOT IN (
    'today','yesterday',
    'this_week','last_week',
    'this_month','last_month',
    'this_quarter','last_quarter',
    'this_year','last_year'
  ) THEN
    RAISE EXCEPTION 'PERIOD_NOT_SUPPORTED: %', p_period_key;
  END IF;

  v_local_reference := timezone(v_timezone, p_reference);

  CASE p_period_key
    WHEN 'today' THEN
      v_start_local := date_trunc('day', v_local_reference);
      v_end_local := v_start_local + interval '1 day';
      v_previous_start_local := v_start_local - interval '1 day';
    WHEN 'yesterday' THEN
      v_end_local := date_trunc('day', v_local_reference);
      v_start_local := v_end_local - interval '1 day';
      v_previous_start_local := v_start_local - interval '1 day';
    WHEN 'this_week' THEN
      v_start_local := date_trunc('week', v_local_reference);
      v_end_local := v_start_local + interval '1 week';
      v_previous_start_local := v_start_local - interval '1 week';
    WHEN 'last_week' THEN
      v_end_local := date_trunc('week', v_local_reference);
      v_start_local := v_end_local - interval '1 week';
      v_previous_start_local := v_start_local - interval '1 week';
    WHEN 'this_month' THEN
      v_start_local := date_trunc('month', v_local_reference);
      v_end_local := v_start_local + interval '1 month';
      v_previous_start_local := v_start_local - interval '1 month';
    WHEN 'last_month' THEN
      v_end_local := date_trunc('month', v_local_reference);
      v_start_local := v_end_local - interval '1 month';
      v_previous_start_local := v_start_local - interval '1 month';
    WHEN 'this_quarter' THEN
      v_start_local := date_trunc('quarter', v_local_reference);
      v_end_local := v_start_local + interval '3 months';
      v_previous_start_local := v_start_local - interval '3 months';
    WHEN 'last_quarter' THEN
      v_end_local := date_trunc('quarter', v_local_reference);
      v_start_local := v_end_local - interval '3 months';
      v_previous_start_local := v_start_local - interval '3 months';
    WHEN 'this_year' THEN
      v_start_local := date_trunc('year', v_local_reference);
      v_end_local := v_start_local + interval '1 year';
      v_previous_start_local := v_start_local - interval '1 year';
    WHEN 'last_year' THEN
      v_end_local := date_trunc('year', v_local_reference);
      v_start_local := v_end_local - interval '1 year';
      v_previous_start_local := v_start_local - interval '1 year';
  END CASE;

  v_previous_end_local := v_start_local;

  RETURN QUERY
  SELECT
    p_period_key,
    v_start_local AT TIME ZONE v_timezone,
    v_end_local AT TIME ZONE v_timezone,
    v_previous_start_local AT TIME ZONE v_timezone,
    v_previous_end_local AT TIME ZONE v_timezone,
    v_timezone;
END;
$$;

CREATE OR REPLACE FUNCTION governance.execute_authorized_metric(
  p_principal_key text,
  p_kpi_key text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_filters jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  allowed boolean,
  reason text,
  kpi_key text,
  query_key text,
  unit text,
  currency_code text,
  start_at timestamptz,
  end_at timestamptz,
  metric_value numeric,
  data_scope text,
  scope_filter_column text,
  scope_values text[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, governance, reporting
AS $$
DECLARE
  v_auth record;
  v_semantics record;
  v_currency text;
  v_filter_keys text[] := '{}'::text[];
  v_requested_filters text[] := ARRAY['date_range']::text[];
  v_sales_rep_filter text[] := '{}'::text[];
  v_lead_source_filter text[] := '{}'::text[];
  v_deal_stage_filter text[] := '{}'::text[];
  v_scope_values text[] := '{}'::text[];
  v_key text;
  v_value jsonb;
  v_values text[];
  v_metric numeric;
BEGIN
  IF p_start_at IS NULL OR p_end_at IS NULL OR p_start_at >= p_end_at THEN
    RETURN QUERY
    SELECT false, 'INVALID_DATE_RANGE', p_kpi_key, NULL::text, NULL::text,
           NULL::text, p_start_at, p_end_at, NULL::numeric,
           'none'::text, NULL::text, '{}'::text[];
    RETURN;
  END IF;

  IF p_filters IS NULL THEN
    p_filters := '{}'::jsonb;
  END IF;

  IF jsonb_typeof(p_filters) <> 'object' THEN
    RETURN QUERY
    SELECT false, 'FILTERS_INVALID', p_kpi_key, NULL::text, NULL::text,
           NULL::text, p_start_at, p_end_at, NULL::numeric,
           'none'::text, NULL::text, '{}'::text[];
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(k.key ORDER BY k.key), '{}'::text[])
  INTO v_filter_keys
  FROM jsonb_object_keys(p_filters) AS k(key);

  IF EXISTS (
    SELECT 1
    FROM unnest(v_filter_keys) AS x(key)
    WHERE key NOT IN ('sales_rep','lead_source','deal_stage')
  ) THEN
    RETURN QUERY
    SELECT false, 'FILTER_FIELD_NOT_SUPPORTED', p_kpi_key, NULL::text, NULL::text,
           NULL::text, p_start_at, p_end_at, NULL::numeric,
           'none'::text, NULL::text, '{}'::text[];
    RETURN;
  END IF;

  IF cardinality(v_filter_keys) > 0 THEN
    v_requested_filters := ARRAY['date_range']::text[] || v_filter_keys;
  END IF;

  FOREACH v_key IN ARRAY v_filter_keys LOOP
    v_value := p_filters -> v_key;

    IF jsonb_typeof(v_value) = 'string' THEN
      v_values := ARRAY[btrim(v_value #>> '{}')];
    ELSIF jsonb_typeof(v_value) = 'array' THEN
      IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_value) AS e(value)
        WHERE jsonb_typeof(e.value) <> 'string'
      ) THEN
        RETURN QUERY
        SELECT false, 'FILTER_VALUE_INVALID', p_kpi_key, NULL::text, NULL::text,
               NULL::text, p_start_at, p_end_at, NULL::numeric,
               'none'::text, NULL::text, '{}'::text[];
        RETURN;
      END IF;

      SELECT COALESCE(
        array_agg(DISTINCT btrim(e.value) ORDER BY btrim(e.value)),
        '{}'::text[]
      )
      INTO v_values
      FROM jsonb_array_elements_text(v_value) AS e(value);
    ELSE
      RETURN QUERY
      SELECT false, 'FILTER_VALUE_INVALID', p_kpi_key, NULL::text, NULL::text,
             NULL::text, p_start_at, p_end_at, NULL::numeric,
             'none'::text, NULL::text, '{}'::text[];
      RETURN;
    END IF;

    IF cardinality(v_values) = 0
       OR cardinality(v_values) > 50
       OR EXISTS (
         SELECT 1 FROM unnest(v_values) AS x(value)
         WHERE value = '' OR length(value) > 200
       ) THEN
      RETURN QUERY
      SELECT false, 'FILTER_VALUE_INVALID', p_kpi_key, NULL::text, NULL::text,
             NULL::text, p_start_at, p_end_at, NULL::numeric,
             'none'::text, NULL::text, '{}'::text[];
      RETURN;
    END IF;

    CASE v_key
      WHEN 'sales_rep' THEN v_sales_rep_filter := v_values;
      WHEN 'lead_source' THEN v_lead_source_filter := v_values;
      WHEN 'deal_stage' THEN v_deal_stage_filter := v_values;
    END CASE;
  END LOOP;

  SELECT *
  INTO v_auth
  FROM governance.authorize_kpi_request(
    p_principal_key,
    p_kpi_key,
    '{}'::text[],
    v_requested_filters
  );

  IF NOT FOUND THEN
    RETURN QUERY
    SELECT false, 'AUTHORIZATION_FAILED',
           p_kpi_key,
           NULL::text,
           NULL::text,
           NULL::text,
           p_start_at,
           p_end_at,
           NULL::numeric,
           'none'::text,
           NULL::text,
           '{}'::text[];
    RETURN;
  END IF;

  IF v_auth.allowed IS DISTINCT FROM true THEN
    RETURN QUERY
    SELECT false,
           COALESCE(v_auth.reason, 'AUTHORIZATION_FAILED'),
           p_kpi_key,
           NULL::text,
           NULL::text,
           NULL::text,
           p_start_at,
           p_end_at,
           NULL::numeric,
           COALESCE(v_auth.data_scope, 'none'),
           v_auth.scope_filter_column,
           COALESCE(v_auth.scope_values, '{}'::text[]);
    RETURN;
  END IF;

  SELECT *
  INTO v_semantics
  FROM governance.resolve_kpi_semantics(p_kpi_key, NULL);

  IF NOT FOUND THEN
    RETURN QUERY
    SELECT false, 'KPI_NOT_APPROVED', p_kpi_key, NULL::text, NULL::text,
           NULL::text, p_start_at, p_end_at, NULL::numeric,
           v_auth.data_scope, v_auth.scope_filter_column, v_auth.scope_values;
    RETURN;
  END IF;

  SELECT trim(both FROM bc.currency_code::text)
  INTO v_currency
  FROM governance.business_config bc
  ORDER BY bc.updated_at DESC
  LIMIT 1;

  v_scope_values := COALESCE(v_auth.scope_values, '{}'::text[]);

  CASE v_semantics.query_key
    WHEN 'closed_won_revenue_v1' THEN
      SELECT COALESCE(SUM(d.amount),0)::numeric(18,2)
      INTO v_metric
      FROM reporting.deals d
      WHERE d.stage_category = 'won'
        AND d.closed_at >= p_start_at
        AND d.closed_at < p_end_at
        AND (cardinality(v_scope_values)=0 OR d.sales_rep = ANY(v_scope_values))
        AND (cardinality(v_sales_rep_filter)=0 OR d.sales_rep = ANY(v_sales_rep_filter))
        AND (cardinality(v_lead_source_filter)=0 OR d.lead_source = ANY(v_lead_source_filter))
        AND (cardinality(v_deal_stage_filter)=0 OR d.stage_name = ANY(v_deal_stage_filter));

    WHEN 'open_pipeline_v1' THEN
      SELECT COALESCE(SUM(d.amount),0)::numeric(18,2)
      INTO v_metric
      FROM reporting.deals d
      WHERE d.stage_category = 'open'
        AND d.expected_close_date >= p_start_at
        AND d.expected_close_date < p_end_at
        AND (cardinality(v_scope_values)=0 OR d.sales_rep = ANY(v_scope_values))
        AND (cardinality(v_sales_rep_filter)=0 OR d.sales_rep = ANY(v_sales_rep_filter))
        AND (cardinality(v_lead_source_filter)=0 OR d.lead_source = ANY(v_lead_source_filter))
        AND (cardinality(v_deal_stage_filter)=0 OR d.stage_name = ANY(v_deal_stage_filter));

    WHEN 'closed_won_deals_v1' THEN
      SELECT COUNT(*)::numeric
      INTO v_metric
      FROM reporting.deals d
      WHERE d.stage_category = 'won'
        AND d.closed_at >= p_start_at
        AND d.closed_at < p_end_at
        AND (cardinality(v_scope_values)=0 OR d.sales_rep = ANY(v_scope_values))
        AND (cardinality(v_sales_rep_filter)=0 OR d.sales_rep = ANY(v_sales_rep_filter))
        AND (cardinality(v_lead_source_filter)=0 OR d.lead_source = ANY(v_lead_source_filter))
        AND (cardinality(v_deal_stage_filter)=0 OR d.stage_name = ANY(v_deal_stage_filter));

    WHEN 'win_rate_v1' THEN
      SELECT ROUND(
        100.0 * COUNT(*) FILTER (WHERE d.stage_category='won')
        / NULLIF(COUNT(*) FILTER (WHERE d.stage_category IN ('won','lost')),0),
        2
      )
      INTO v_metric
      FROM reporting.deals d
      WHERE d.stage_category IN ('won','lost')
        AND d.closed_at >= p_start_at
        AND d.closed_at < p_end_at
        AND (cardinality(v_scope_values)=0 OR d.sales_rep = ANY(v_scope_values))
        AND (cardinality(v_sales_rep_filter)=0 OR d.sales_rep = ANY(v_sales_rep_filter))
        AND (cardinality(v_lead_source_filter)=0 OR d.lead_source = ANY(v_lead_source_filter))
        AND (cardinality(v_deal_stage_filter)=0 OR d.stage_name = ANY(v_deal_stage_filter));

    ELSE
      RETURN QUERY
      SELECT false, 'QUERY_NOT_EXECUTABLE', p_kpi_key, v_semantics.query_key,
             v_semantics.unit, v_currency, p_start_at, p_end_at, NULL::numeric,
             v_auth.data_scope, v_auth.scope_filter_column, v_scope_values;
      RETURN;
  END CASE;

  RETURN QUERY
  SELECT true, 'AUTHORIZED', p_kpi_key, v_semantics.query_key,
         v_semantics.unit, v_currency, p_start_at, p_end_at, v_metric,
         v_auth.data_scope, v_auth.scope_filter_column, v_scope_values;
END;
$$;

CREATE OR REPLACE FUNCTION governance.execute_agent_metric_request(
  p_principal_key text,
  p_kpi_key text,
  p_period_key text,
  p_mode text DEFAULT 'metric_report',
  p_filters jsonb DEFAULT '{}'::jsonb,
  p_reference timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
DECLARE
  v_period record;
  v_current record;
  v_previous record;
  v_compare boolean;
  v_delta numeric;
  v_percent_change numeric;
  v_direction text;
BEGIN
  IF p_mode NOT IN ('metric_report','trend_report','comparison_report') THEN
    RETURN jsonb_build_object(
      'status','rejected',
      'reason','REPORT_MODE_NOT_SUPPORTED'
    );
  END IF;

  SELECT *
  INTO v_period
  FROM governance.resolve_relative_period(p_period_key, p_reference);

  SELECT *
  INTO v_current
  FROM governance.execute_authorized_metric(
    p_principal_key,
    p_kpi_key,
    v_period.start_at,
    v_period.end_at,
    p_filters
  );

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status','rejected',
      'reason','AUTHORIZATION_FAILED',
      'kpi_key',p_kpi_key,
      'period_key',p_period_key
    );
  END IF;

  IF v_current.allowed IS DISTINCT FROM true THEN
    RETURN jsonb_build_object(
      'status','rejected',
      'reason',COALESCE(v_current.reason,'AUTHORIZATION_FAILED'),
      'kpi_key',p_kpi_key,
      'period_key',p_period_key
    );
  END IF;

  -- Initialize the record so scalar metric reports can build the final
  -- JSON contract without touching an unassigned PL/pgSQL record.
  v_previous := v_current;

  v_compare := p_mode IN ('trend_report','comparison_report');

  IF v_compare THEN
    SELECT *
    INTO v_previous
    FROM governance.execute_authorized_metric(
      p_principal_key,
      p_kpi_key,
      v_period.previous_start_at,
      v_period.previous_end_at,
      p_filters
    );

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'status','rejected',
        'reason','PREVIOUS_PERIOD_EXECUTION_FAILED',
        'kpi_key',p_kpi_key,
        'period_key',p_period_key
      );
    END IF;

    IF v_previous.allowed IS DISTINCT FROM true THEN
      RETURN jsonb_build_object(
        'status','rejected',
        'reason',COALESCE(v_previous.reason,'PREVIOUS_PERIOD_EXECUTION_FAILED'),
        'kpi_key',p_kpi_key,
        'period_key',p_period_key
      );
    END IF;

    IF v_current.metric_value IS NOT NULL AND v_previous.metric_value IS NOT NULL THEN
      v_delta := v_current.metric_value - v_previous.metric_value;

      IF v_previous.metric_value <> 0 THEN
        v_percent_change := round(
          100.0 * v_delta / abs(v_previous.metric_value),
          2
        );
      END IF;

      v_direction := CASE
        WHEN v_delta > 0 THEN 'up'
        WHEN v_delta < 0 THEN 'down'
        ELSE 'flat'
      END;
    ELSE
      v_direction := 'unavailable';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'status','approved',
    'kpi_key',p_kpi_key,
    'query_key',v_current.query_key,
    'unit',v_current.unit,
    'currency_code',v_current.currency_code,
    'mode',p_mode,
    'reporting_timezone',v_period.reporting_timezone,
    'data_scope',v_current.data_scope,
    'current_period',jsonb_build_object(
      'period_key',p_period_key,
      'start_at',v_period.start_at,
      'end_at',v_period.end_at,
      'value',v_current.metric_value
    ),
    'previous_period',CASE
      WHEN v_compare THEN jsonb_build_object(
        'start_at',v_period.previous_start_at,
        'end_at',v_period.previous_end_at,
        'value',v_previous.metric_value
      )
      ELSE NULL
    END,
    'analysis',CASE
      WHEN v_compare THEN jsonb_build_object(
        'delta',v_delta,
        'percent_change',v_percent_change,
        'direction',v_direction
      )
      ELSE NULL
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION governance.resolve_relative_period(text,timestamptz)
FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.execute_authorized_metric(
  text,text,timestamptz,timestamptz,jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.execute_agent_metric_request(
  text,text,text,text,jsonb,timestamptz
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION governance.resolve_relative_period(text,timestamptz)
TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.execute_authorized_metric(
  text,text,timestamptz,timestamptz,jsonb
) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.execute_agent_metric_request(
  text,text,text,text,jsonb,timestamptz
) TO revint_governance_ro;

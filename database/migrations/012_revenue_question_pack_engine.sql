\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION governance.filter_values_v2(
  p_filters jsonb,
  p_key text
)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT CASE
    WHEN p_filters IS NULL OR NOT (p_filters ? p_key) THEN '{}'::text[]
    WHEN jsonb_typeof(p_filters->p_key)='string'
      THEN ARRAY[btrim(p_filters->>p_key)]
    WHEN jsonb_typeof(p_filters->p_key)='array'
      THEN COALESCE((
        SELECT array_agg(DISTINCT btrim(value) ORDER BY btrim(value))
        FROM jsonb_array_elements_text(p_filters->p_key) AS e(value)
      ),'{}'::text[])
    ELSE '{}'::text[]
  END;
$$;

CREATE OR REPLACE FUNCTION governance.validate_report_filters_v2(
  p_filters jsonb
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_key text;
  v_value jsonb;
  v_values text[];
BEGIN
  IF p_filters IS NULL THEN
    RETURN NULL;
  END IF;

  IF jsonb_typeof(p_filters)<>'object' THEN
    RETURN 'FILTERS_INVALID';
  END IF;

  FOR v_key,v_value IN
    SELECT key,value FROM jsonb_each(p_filters)
  LOOP
    IF v_key NOT IN (
      'sales_rep','lead_source','deal_stage','segment','region',
      'industry','campaign','forecast_category'
    ) THEN
      RETURN 'FILTER_FIELD_NOT_SUPPORTED';
    END IF;

    IF jsonb_typeof(v_value)='string' THEN
      v_values := ARRAY[btrim(v_value #>> '{}')];
    ELSIF jsonb_typeof(v_value)='array' THEN
      IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_value) e(value)
        WHERE jsonb_typeof(e.value)<>'string'
      ) THEN
        RETURN 'FILTER_VALUE_INVALID';
      END IF;

      SELECT COALESCE(
        array_agg(DISTINCT btrim(value) ORDER BY btrim(value)),
        '{}'::text[]
      )
      INTO v_values
      FROM jsonb_array_elements_text(v_value) e(value);
    ELSE
      RETURN 'FILTER_VALUE_INVALID';
    END IF;

    IF cardinality(v_values)=0
       OR cardinality(v_values)>50
       OR EXISTS (
         SELECT 1 FROM unnest(v_values) x(value)
         WHERE value='' OR length(value)>200
       ) THEN
      RETURN 'FILTER_VALUE_INVALID';
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION governance.filtered_deals_v2(
  p_scope_values text[],
  p_filters jsonb
)
RETURNS SETOF reporting.deals
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
  SELECT d.*
  FROM reporting.deals d
  WHERE
    (cardinality(COALESCE(p_scope_values,'{}'::text[]))=0
      OR d.sales_rep=ANY(p_scope_values))
    AND (
      cardinality(governance.filter_values_v2(p_filters,'sales_rep'))=0
      OR d.sales_rep=ANY(governance.filter_values_v2(p_filters,'sales_rep'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'lead_source'))=0
      OR d.lead_source=ANY(governance.filter_values_v2(p_filters,'lead_source'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'deal_stage'))=0
      OR d.stage_name=ANY(governance.filter_values_v2(p_filters,'deal_stage'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'segment'))=0
      OR d.segment=ANY(governance.filter_values_v2(p_filters,'segment'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'region'))=0
      OR d.region=ANY(governance.filter_values_v2(p_filters,'region'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'industry'))=0
      OR d.industry=ANY(governance.filter_values_v2(p_filters,'industry'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'campaign'))=0
      OR d.campaign=ANY(governance.filter_values_v2(p_filters,'campaign'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'forecast_category'))=0
      OR d.forecast_category=ANY(governance.filter_values_v2(p_filters,'forecast_category'))
    );
$$;

CREATE OR REPLACE FUNCTION governance.filtered_funnel_records_v2(
  p_scope_values text[],
  p_filters jsonb
)
RETURNS SETOF reporting.funnel_records
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
  SELECT f.*
  FROM reporting.funnel_records f
  WHERE
    (cardinality(COALESCE(p_scope_values,'{}'::text[]))=0
      OR f.sales_rep=ANY(p_scope_values))
    AND (
      cardinality(governance.filter_values_v2(p_filters,'sales_rep'))=0
      OR f.sales_rep=ANY(governance.filter_values_v2(p_filters,'sales_rep'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'lead_source'))=0
      OR f.lead_source=ANY(governance.filter_values_v2(p_filters,'lead_source'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'segment'))=0
      OR f.segment=ANY(governance.filter_values_v2(p_filters,'segment'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'region'))=0
      OR f.region=ANY(governance.filter_values_v2(p_filters,'region'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'industry'))=0
      OR f.industry=ANY(governance.filter_values_v2(p_filters,'industry'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'campaign'))=0
      OR f.campaign=ANY(governance.filter_values_v2(p_filters,'campaign'))
    );
$$;

CREATE OR REPLACE FUNCTION governance.filtered_activities_v2(
  p_scope_values text[],
  p_filters jsonb
)
RETURNS SETOF reporting.activities
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
  SELECT a.*
  FROM reporting.activities a
  WHERE
    (cardinality(COALESCE(p_scope_values,'{}'::text[]))=0
      OR a.sales_rep=ANY(p_scope_values))
    AND (
      cardinality(governance.filter_values_v2(p_filters,'sales_rep'))=0
      OR a.sales_rep=ANY(governance.filter_values_v2(p_filters,'sales_rep'))
    );
$$;

CREATE OR REPLACE FUNCTION governance.filtered_subscription_events_v2(
  p_scope_values text[],
  p_filters jsonb
)
RETURNS SETOF reporting.subscription_events
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
  SELECT s.*
  FROM reporting.subscription_events s
  WHERE
    (cardinality(COALESCE(p_scope_values,'{}'::text[]))=0
      OR s.sales_rep=ANY(p_scope_values))
    AND (
      cardinality(governance.filter_values_v2(p_filters,'sales_rep'))=0
      OR s.sales_rep=ANY(governance.filter_values_v2(p_filters,'sales_rep'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'segment'))=0
      OR s.segment=ANY(governance.filter_values_v2(p_filters,'segment'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'region'))=0
      OR s.region=ANY(governance.filter_values_v2(p_filters,'region'))
    )
    AND (
      cardinality(governance.filter_values_v2(p_filters,'industry'))=0
      OR s.industry=ANY(governance.filter_values_v2(p_filters,'industry'))
    );
$$;

CREATE OR REPLACE FUNCTION governance.metric_data_domains_ready_v2(
  p_kpi_key text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance
AS $$
DECLARE
  v_domains text[];
  v_missing text[];
BEGIN
  SELECT required_data_domains
  INTO v_domains
  FROM governance.kpi_catalog
  WHERE kpi_key=p_kpi_key AND active
  ORDER BY version DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ready',false,'reason','KPI_NOT_APPROVED','missing_domains','[]'::jsonb
    );
  END IF;

  SELECT COALESCE(array_agg(req.domain_key ORDER BY req.domain_key),'{}'::text[])
  INTO v_missing
  FROM unnest(COALESCE(v_domains,'{}'::text[])) req(domain_key)
  LEFT JOIN governance.data_domain_status s
    ON s.domain_key=req.domain_key
   AND s.active
   AND s.data_ready
  WHERE s.domain_key IS NULL;

  RETURN jsonb_build_object(
    'ready',cardinality(v_missing)=0,
    'required_domains',to_jsonb(COALESCE(v_domains,'{}'::text[])),
    'missing_domains',to_jsonb(v_missing)
  );
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.mark_data_domain_ready_v2(
  p_domain_key text,
  p_record_count bigint,
  p_loaded_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,governance
AS $$
BEGIN
  IF p_record_count<0 THEN
    RAISE EXCEPTION 'DATA_DOMAIN_RECORD_COUNT_INVALID';
  END IF;

  UPDATE governance.data_domain_status
  SET data_ready=true,
      record_count=p_record_count,
      last_loaded_at=p_loaded_at,
      updated_at=now()
  WHERE domain_key=p_domain_key AND active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DATA_DOMAIN_NOT_REGISTERED: %',p_domain_key;
  END IF;

  RETURN jsonb_build_object(
    'status','ready',
    'domain_key',p_domain_key,
    'record_count',p_record_count,
    'last_loaded_at',p_loaded_at
  );
END;
$$;

REVOKE ALL ON FUNCTION governance.filter_values_v2(jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.validate_report_filters_v2(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.filtered_deals_v2(text[],jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.filtered_funnel_records_v2(text[],jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.filtered_activities_v2(text[],jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.filtered_subscription_events_v2(text[],jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.metric_data_domains_ready_v2(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.mark_data_domain_ready_v2(text,bigint,timestamptz) FROM PUBLIC;

GRANT SELECT ON governance.data_domain_status TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.filter_values_v2(jsonb,text) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.validate_report_filters_v2(jsonb) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.filtered_deals_v2(text[],jsonb) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.filtered_funnel_records_v2(text[],jsonb) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.filtered_activities_v2(text[],jsonb) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.filtered_subscription_events_v2(text[],jsonb) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.metric_data_domains_ready_v2(text) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION ingestion.mark_data_domain_ready_v2(text,bigint,timestamptz)
TO revint_connector_ingest;

CREATE OR REPLACE FUNCTION governance.compute_deal_metric_v2(
  p_kpi_key text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_dimension text,
  p_scope_values text[],
  p_filters jsonb,
  p_max_rows integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
DECLARE
  v_value numeric;
  v_num numeric;
  v_den numeric;
  v_count bigint;
  v_count2 bigint;
  v_populated bigint;
  v_stale_days integer;
  v_as_of timestamptz := LEAST(p_end_at,now());
  v_rows jsonb;
  v_gate jsonb;
BEGIN
  SELECT stale_deal_days INTO v_stale_days
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;

  IF p_dimension IS NOT NULL THEN
    v_gate := governance.compute_deal_metric_v2(
      p_kpi_key,p_start_at,p_end_at,NULL,p_scope_values,p_filters,p_max_rows
    );
    IF v_gate->>'status'<>'approved' THEN
      RETURN v_gate;
    END IF;

    SELECT COALESCE(jsonb_agg(
      jsonb_build_object('dimension_value',dimension_value,'value',metric_value)
      ORDER BY metric_value DESC NULLS LAST,dimension_value
    ),'[]'::jsonb)
    INTO v_rows
    FROM (
      WITH base AS (
        SELECT
          CASE p_dimension
            WHEN 'sales_rep' THEN COALESCE(NULLIF(btrim(sales_rep),''),'Unassigned')
            WHEN 'lead_source' THEN COALESCE(NULLIF(btrim(lead_source),''),'Unassigned')
            WHEN 'deal_stage' THEN COALESCE(NULLIF(btrim(stage_name),''),'Unassigned')
            WHEN 'segment' THEN COALESCE(NULLIF(btrim(segment),''),'Unassigned')
            WHEN 'region' THEN COALESCE(NULLIF(btrim(region),''),'Unassigned')
            WHEN 'industry' THEN COALESCE(NULLIF(btrim(industry),''),'Unassigned')
            WHEN 'campaign' THEN COALESCE(NULLIF(btrim(campaign),''),'Unassigned')
            WHEN 'forecast_category' THEN COALESCE(NULLIF(btrim(forecast_category),''),'Unassigned')
            ELSE NULL
          END AS dimension_value,
          d.*
        FROM governance.filtered_deals_v2(p_scope_values,p_filters) d
      )
      SELECT dimension_value,
        CASE p_kpi_key
          WHEN 'closed_won_revenue' THEN
            COALESCE(sum(amount) FILTER (
              WHERE stage_category='won'
                AND closed_at>=p_start_at AND closed_at<p_end_at
            ),0)::numeric
          WHEN 'open_pipeline' THEN
            COALESCE(sum(amount) FILTER (
              WHERE stage_category='open'
                AND expected_close_date>=p_start_at AND expected_close_date<p_end_at
            ),0)::numeric
          WHEN 'closed_won_deals' THEN
            count(*) FILTER (
              WHERE stage_category='won'
                AND closed_at>=p_start_at AND closed_at<p_end_at
            )::numeric
          WHEN 'win_rate' THEN
            round(
              100.0 * count(*) FILTER (
                WHERE stage_category='won'
                  AND closed_at>=p_start_at AND closed_at<p_end_at
              )
              / NULLIF(count(*) FILTER (
                WHERE stage_category IN ('won','lost')
                  AND closed_at>=p_start_at AND closed_at<p_end_at
              ),0),
              2
            )
          WHEN 'open_deals_count' THEN
            count(*) FILTER (
              WHERE stage_category='open'
                AND expected_close_date>=p_start_at AND expected_close_date<p_end_at
            )::numeric
          WHEN 'weighted_pipeline' THEN
            COALESCE(sum(amount*probability_percent/100.0) FILTER (
              WHERE stage_category='open'
                AND expected_close_date>=p_start_at AND expected_close_date<p_end_at
            ),0)::numeric
          WHEN 'stale_open_deals_count' THEN
            count(*) FILTER (
              WHERE stage_category='open'
                AND expected_close_date>=p_start_at AND expected_close_date<p_end_at
                AND COALESCE(last_activity_at,source_updated_at,created_at,ingested_at)
                    < v_as_of-make_interval(days=>v_stale_days)
            )::numeric
          WHEN 'stale_pipeline_value' THEN
            COALESCE(sum(amount) FILTER (
              WHERE stage_category='open'
                AND expected_close_date>=p_start_at AND expected_close_date<p_end_at
                AND COALESCE(last_activity_at,source_updated_at,created_at,ingested_at)
                    < v_as_of-make_interval(days=>v_stale_days)
            ),0)::numeric
          WHEN 'missing_close_date_deals' THEN
            count(*) FILTER (
              WHERE stage_category='open'
                AND expected_close_date IS NULL
                AND created_at>=p_start_at AND created_at<p_end_at
            )::numeric
          WHEN 'average_deal_size' THEN
            COALESCE(round(avg(amount) FILTER (
              WHERE stage_category='won'
                AND closed_at>=p_start_at AND closed_at<p_end_at
            ),2),0)::numeric
          WHEN 'closed_lost_deals' THEN
            count(*) FILTER (
              WHERE stage_category='lost'
                AND closed_at>=p_start_at AND closed_at<p_end_at
            )::numeric
          WHEN 'loss_rate' THEN
            round(
              100.0 * count(*) FILTER (
                WHERE stage_category='lost'
                  AND closed_at>=p_start_at AND closed_at<p_end_at
              )
              / NULLIF(count(*) FILTER (
                WHERE stage_category IN ('won','lost')
                  AND closed_at>=p_start_at AND closed_at<p_end_at
              ),0),
              2
            )
          WHEN 'average_acv' THEN
            COALESCE(round(avg(annual_contract_value) FILTER (
              WHERE stage_category='won'
                AND closed_at>=p_start_at AND closed_at<p_end_at
            ),2),0)::numeric
          WHEN 'average_discount_percent' THEN
            COALESCE(round(avg(discount_percent) FILTER (
              WHERE stage_category='won'
                AND closed_at>=p_start_at AND closed_at<p_end_at
            ),2),0)::numeric
          WHEN 'commit_forecast' THEN
            COALESCE(sum(amount) FILTER (
              WHERE stage_category='open'
                AND forecast_category='commit'
                AND expected_close_date>=p_start_at AND expected_close_date<p_end_at
            ),0)::numeric
          WHEN 'best_case_forecast' THEN
            COALESCE(sum(amount) FILTER (
              WHERE stage_category='open'
                AND forecast_category='best_case'
                AND expected_close_date>=p_start_at AND expected_close_date<p_end_at
            ),0)::numeric
          WHEN 'average_sales_cycle_days' THEN
            COALESCE(round(avg(
              extract(epoch FROM (closed_at-created_at))/86400.0
            ) FILTER (
              WHERE stage_category IN ('won','lost')
                AND created_at IS NOT NULL
                AND closed_at>=p_start_at AND closed_at<p_end_at
            ),2),0)::numeric
          WHEN 'average_stage_age_days' THEN
            COALESCE(round(avg(
              extract(epoch FROM (v_as_of-stage_entered_at))/86400.0
            ) FILTER (
              WHERE stage_category='open'
                AND stage_entered_at IS NOT NULL
                AND expected_close_date>=p_start_at AND expected_close_date<p_end_at
            ),2),0)::numeric
          WHEN 'crm_data_quality_score' THEN
            round(
              100.0 * sum(
                CASE WHEN created_at>=p_start_at AND created_at<p_end_at THEN
                  (CASE WHEN NULLIF(btrim(COALESCE(deal_name,'')),'') IS NOT NULL THEN 1 ELSE 0 END) +
                  (CASE WHEN NULLIF(btrim(COALESCE(sales_rep,'')),'') IS NOT NULL THEN 1 ELSE 0 END) +
                  (CASE WHEN NULLIF(btrim(COALESCE(lead_source,'')),'') IS NOT NULL THEN 1 ELSE 0 END) +
                  (CASE WHEN NULLIF(btrim(COALESCE(stage_name,'')),'') IS NOT NULL THEN 1 ELSE 0 END) +
                  (CASE WHEN amount>=0 THEN 1 ELSE 0 END) +
                  (CASE WHEN stage_category='open'
                          THEN CASE WHEN expected_close_date IS NOT NULL THEN 1 ELSE 0 END
                        ELSE CASE WHEN closed_at IS NOT NULL THEN 1 ELSE 0 END
                    END)
                ELSE 0 END
              )
              / NULLIF(
                count(*) FILTER (
                  WHERE created_at>=p_start_at AND created_at<p_end_at
                )*6.0,
                0
              ),
              2
            )
          WHEN 'missing_owner_deals' THEN
            count(*) FILTER (
              WHERE created_at>=p_start_at AND created_at<p_end_at
                AND NULLIF(btrim(COALESCE(sales_rep,'')),'') IS NULL
            )::numeric
          ELSE NULL::numeric
        END AS metric_value
      FROM base
      WHERE dimension_value IS NOT NULL
      GROUP BY dimension_value
      ORDER BY metric_value DESC NULLS LAST,dimension_value
      LIMIT GREATEST(1,LEAST(COALESCE(p_max_rows,100),1000))
    ) grouped_metrics;

    IF p_kpi_key='pipeline_velocity' THEN
      RETURN jsonb_build_object(
        'status','rejected','reason','BREAKDOWN_QUERY_NOT_EXECUTABLE'
      );
    END IF;

    RETURN jsonb_build_object(
      'status','approved',
      'result_type','breakdown',
      'dimension_key',p_dimension,
      'rows',v_rows
    );
  END IF;

  CASE p_kpi_key
    WHEN 'closed_won_revenue' THEN
      SELECT COALESCE(sum(amount),0)::numeric(18,2)
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='won'
        AND closed_at>=p_start_at AND closed_at<p_end_at;

    WHEN 'open_pipeline' THEN
      SELECT COALESCE(sum(amount),0)::numeric(18,2)
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='open'
        AND expected_close_date>=p_start_at AND expected_close_date<p_end_at;

    WHEN 'closed_won_deals' THEN
      SELECT count(*)::numeric
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='won'
        AND closed_at>=p_start_at AND closed_at<p_end_at;

    WHEN 'win_rate' THEN
      SELECT round(
        100.0 * count(*) FILTER (WHERE stage_category='won')
        / NULLIF(count(*) FILTER (WHERE stage_category IN ('won','lost')),0),
        2
      )
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category IN ('won','lost')
        AND closed_at>=p_start_at AND closed_at<p_end_at;

    WHEN 'open_deals_count' THEN
      SELECT count(*)::numeric
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='open'
        AND expected_close_date>=p_start_at AND expected_close_date<p_end_at;

    WHEN 'weighted_pipeline' THEN
      SELECT count(*),count(probability_percent),
             COALESCE(sum(amount*probability_percent/100.0),0)::numeric(18,2)
      INTO v_count,v_populated,v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='open'
        AND expected_close_date>=p_start_at AND expected_close_date<p_end_at;
      IF v_count>0 AND v_populated<v_count THEN
        RETURN jsonb_build_object(
          'status','unavailable',
          'reason','PROBABILITY_COVERAGE_INCOMPLETE',
          'eligible_records',v_count,
          'populated_records',v_populated
        );
      END IF;

    WHEN 'stale_open_deals_count' THEN
      SELECT count(*)::numeric
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='open'
        AND expected_close_date>=p_start_at AND expected_close_date<p_end_at
        AND COALESCE(last_activity_at,source_updated_at,created_at,ingested_at)
            < v_as_of-make_interval(days=>v_stale_days);

    WHEN 'stale_pipeline_value' THEN
      SELECT COALESCE(sum(amount),0)::numeric(18,2)
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='open'
        AND expected_close_date>=p_start_at AND expected_close_date<p_end_at
        AND COALESCE(last_activity_at,source_updated_at,created_at,ingested_at)
            < v_as_of-make_interval(days=>v_stale_days);

    WHEN 'missing_close_date_deals' THEN
      SELECT count(*)::numeric
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='open'
        AND expected_close_date IS NULL
        AND created_at>=p_start_at AND created_at<p_end_at;

    WHEN 'average_deal_size' THEN
      SELECT COALESCE(round(avg(amount),2),0)
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='won'
        AND closed_at>=p_start_at AND closed_at<p_end_at;

    WHEN 'closed_lost_deals' THEN
      SELECT count(*)::numeric
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='lost'
        AND closed_at>=p_start_at AND closed_at<p_end_at;

    WHEN 'loss_rate' THEN
      SELECT round(
        100.0 * count(*) FILTER (WHERE stage_category='lost')
        / NULLIF(count(*) FILTER (WHERE stage_category IN ('won','lost')),0),
        2
      )
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category IN ('won','lost')
        AND closed_at>=p_start_at AND closed_at<p_end_at;

    WHEN 'average_acv' THEN
      SELECT count(*),count(annual_contract_value),
             COALESCE(round(avg(annual_contract_value),2),0)
      INTO v_count,v_populated,v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='won'
        AND closed_at>=p_start_at AND closed_at<p_end_at;
      IF v_count>0 AND v_populated<v_count THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','ACV_COVERAGE_INCOMPLETE'
        );
      END IF;

    WHEN 'average_discount_percent' THEN
      SELECT count(*),count(discount_percent),
             COALESCE(round(avg(discount_percent),2),0)
      INTO v_count,v_populated,v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='won'
        AND closed_at>=p_start_at AND closed_at<p_end_at;
      IF v_count>0 AND v_populated<v_count THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','DISCOUNT_COVERAGE_INCOMPLETE'
        );
      END IF;

    WHEN 'commit_forecast' THEN
      SELECT count(*),count(forecast_category),
             COALESCE(sum(amount) FILTER (WHERE forecast_category='commit'),0)
      INTO v_count,v_populated,v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='open'
        AND expected_close_date>=p_start_at AND expected_close_date<p_end_at;
      IF v_count>0 AND v_populated<v_count THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','FORECAST_CATEGORY_COVERAGE_INCOMPLETE'
        );
      END IF;

    WHEN 'best_case_forecast' THEN
      SELECT count(*),count(forecast_category),
             COALESCE(sum(amount) FILTER (WHERE forecast_category='best_case'),0)
      INTO v_count,v_populated,v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='open'
        AND expected_close_date>=p_start_at AND expected_close_date<p_end_at;
      IF v_count>0 AND v_populated<v_count THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','FORECAST_CATEGORY_COVERAGE_INCOMPLETE'
        );
      END IF;

    WHEN 'average_sales_cycle_days' THEN
      SELECT count(*),count(created_at),
             COALESCE(round(
               avg(extract(epoch FROM (closed_at-created_at))/86400.0),2
             ),0)
      INTO v_count,v_populated,v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category IN ('won','lost')
        AND closed_at>=p_start_at AND closed_at<p_end_at;
      IF v_count>0 AND v_populated<v_count THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','CREATED_DATE_COVERAGE_INCOMPLETE'
        );
      END IF;

    WHEN 'average_stage_age_days' THEN
      SELECT count(*),count(stage_entered_at),
             COALESCE(round(
               avg(extract(epoch FROM (v_as_of-stage_entered_at))/86400.0),2
             ),0)
      INTO v_count,v_populated,v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='open'
        AND expected_close_date>=p_start_at AND expected_close_date<p_end_at;
      IF v_count>0 AND v_populated<v_count THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','STAGE_ENTERED_COVERAGE_INCOMPLETE'
        );
      END IF;

    WHEN 'pipeline_velocity' THEN
      SELECT count(*)::numeric
      INTO v_count
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category='open'
        AND expected_close_date>=p_start_at AND expected_close_date<p_end_at;

      SELECT avg(amount) FILTER (WHERE stage_category='won'),
             1.0*count(*) FILTER (WHERE stage_category='won')
               / NULLIF(count(*) FILTER (WHERE stage_category IN ('won','lost')),0),
             avg(extract(epoch FROM (closed_at-created_at))/86400.0)
               FILTER (WHERE stage_category='won' AND created_at IS NOT NULL)
      INTO v_num,v_den,v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE stage_category IN ('won','lost')
        AND closed_at>=p_start_at AND closed_at<p_end_at;

      IF v_num IS NULL OR v_den IS NULL OR v_value IS NULL OR v_value=0 THEN
        RETURN jsonb_build_object(
          'status','unavailable',
          'reason','PIPELINE_VELOCITY_INPUTS_NOT_AVAILABLE'
        );
      END IF;
      v_value := round(v_count*v_num*v_den/v_value,2);

    WHEN 'crm_data_quality_score' THEN
      SELECT count(*),
             round(
               100.0*sum(
                 (CASE WHEN NULLIF(btrim(COALESCE(deal_name,'')),'') IS NOT NULL THEN 1 ELSE 0 END)+
                 (CASE WHEN NULLIF(btrim(COALESCE(sales_rep,'')),'') IS NOT NULL THEN 1 ELSE 0 END)+
                 (CASE WHEN NULLIF(btrim(COALESCE(lead_source,'')),'') IS NOT NULL THEN 1 ELSE 0 END)+
                 (CASE WHEN NULLIF(btrim(COALESCE(stage_name,'')),'') IS NOT NULL THEN 1 ELSE 0 END)+
                 (CASE WHEN amount>=0 THEN 1 ELSE 0 END)+
                 (CASE WHEN stage_category='open'
                    THEN CASE WHEN expected_close_date IS NOT NULL THEN 1 ELSE 0 END
                    ELSE CASE WHEN closed_at IS NOT NULL THEN 1 ELSE 0 END
                  END)
               )/NULLIF(count(*)*6.0,0),
               2
             )
      INTO v_count,v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE created_at>=p_start_at AND created_at<p_end_at;
      IF v_count=0 THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','DEAL_DATA_NOT_AVAILABLE_FOR_PERIOD'
        );
      END IF;

    WHEN 'missing_owner_deals' THEN
      SELECT count(*)::numeric
      INTO v_value
      FROM governance.filtered_deals_v2(p_scope_values,p_filters)
      WHERE created_at>=p_start_at AND created_at<p_end_at
        AND NULLIF(btrim(COALESCE(sales_rep,'')),'') IS NULL;

    ELSE
      RETURN jsonb_build_object(
        'status','rejected','reason','QUERY_NOT_EXECUTABLE'
      );
  END CASE;

  RETURN jsonb_build_object(
    'status','approved','result_type','scalar','value',v_value
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.compute_funnel_metric_v2(
  p_kpi_key text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_dimension text,
  p_scope_values text[],
  p_filters jsonb,
  p_max_rows integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
DECLARE
  v_count bigint;
  v_count2 bigint;
  v_populated bigint;
  v_value numeric;
  v_rows jsonb;
  v_gate jsonb;
BEGIN
  IF p_dimension IS NOT NULL THEN
    v_gate := governance.compute_funnel_metric_v2(
      p_kpi_key,p_start_at,p_end_at,NULL,p_scope_values,p_filters,p_max_rows
    );
    IF v_gate->>'status'<>'approved' THEN
      RETURN v_gate;
    END IF;

    SELECT COALESCE(jsonb_agg(
      jsonb_build_object('dimension_value',dimension_value,'value',metric_value)
      ORDER BY metric_value DESC NULLS LAST,dimension_value
    ),'[]'::jsonb)
    INTO v_rows
    FROM (
      WITH base AS (
        SELECT
          CASE p_dimension
            WHEN 'sales_rep' THEN COALESCE(NULLIF(btrim(sales_rep),''),'Unassigned')
            WHEN 'lead_source' THEN COALESCE(NULLIF(btrim(lead_source),''),'Unassigned')
            WHEN 'segment' THEN COALESCE(NULLIF(btrim(segment),''),'Unassigned')
            WHEN 'region' THEN COALESCE(NULLIF(btrim(region),''),'Unassigned')
            WHEN 'industry' THEN COALESCE(NULLIF(btrim(industry),''),'Unassigned')
            WHEN 'campaign' THEN COALESCE(NULLIF(btrim(campaign),''),'Unassigned')
            ELSE NULL
          END AS dimension_value,
          f.*
        FROM governance.filtered_funnel_records_v2(p_scope_values,p_filters) f
        WHERE created_at>=p_start_at AND created_at<p_end_at
      )
      SELECT dimension_value,
        CASE p_kpi_key
          WHEN 'lead_to_mql_rate' THEN
            round(100.0*count(mql_at)/NULLIF(count(*),0),2)
          WHEN 'mql_to_sql_rate' THEN
            round(
              100.0*count(*) FILTER (WHERE mql_at IS NOT NULL AND sql_at IS NOT NULL)
              / NULLIF(count(*) FILTER (WHERE mql_at IS NOT NULL),0),
              2
            )
          WHEN 'sql_to_opportunity_rate' THEN
            round(
              100.0*count(*) FILTER (
                WHERE sql_at IS NOT NULL AND opportunity_at IS NOT NULL
              )
              / NULLIF(count(*) FILTER (WHERE sql_at IS NOT NULL),0),
              2
            )
          WHEN 'opportunity_to_won_rate' THEN
            round(
              100.0*count(*) FILTER (
                WHERE opportunity_at IS NOT NULL AND won_at IS NOT NULL
              )
              / NULLIF(count(*) FILTER (WHERE opportunity_at IS NOT NULL),0),
              2
            )
          WHEN 'speed_to_lead_hours' THEN
            round(avg(extract(epoch FROM (first_response_at-created_at))/3600.0),2)
          ELSE NULL::numeric
        END AS metric_value
      FROM base
      WHERE dimension_value IS NOT NULL
      GROUP BY dimension_value
      ORDER BY metric_value DESC NULLS LAST,dimension_value
      LIMIT GREATEST(1,LEAST(COALESCE(p_max_rows,100),1000))
    ) grouped_metrics;

    RETURN jsonb_build_object(
      'status','approved',
      'result_type','breakdown',
      'dimension_key',p_dimension,
      'rows',v_rows
    );
  END IF;

  CASE p_kpi_key
    WHEN 'lead_to_mql_rate' THEN
      SELECT count(*),count(mql_at)
      INTO v_count,v_count2
      FROM governance.filtered_funnel_records_v2(p_scope_values,p_filters)
      WHERE created_at>=p_start_at AND created_at<p_end_at;
      IF v_count=0 THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','FUNNEL_DATA_NOT_AVAILABLE'
        );
      END IF;
      v_value := round(100.0*v_count2/v_count,2);

    WHEN 'mql_to_sql_rate' THEN
      SELECT count(*) FILTER (WHERE mql_at IS NOT NULL),
             count(*) FILTER (WHERE mql_at IS NOT NULL AND sql_at IS NOT NULL)
      INTO v_count,v_count2
      FROM governance.filtered_funnel_records_v2(p_scope_values,p_filters)
      WHERE created_at>=p_start_at AND created_at<p_end_at;
      IF v_count=0 THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','MQL_DATA_NOT_AVAILABLE'
        );
      END IF;
      v_value := round(100.0*v_count2/v_count,2);

    WHEN 'sql_to_opportunity_rate' THEN
      SELECT count(*) FILTER (WHERE sql_at IS NOT NULL),
             count(*) FILTER (
               WHERE sql_at IS NOT NULL AND opportunity_at IS NOT NULL
             )
      INTO v_count,v_count2
      FROM governance.filtered_funnel_records_v2(p_scope_values,p_filters)
      WHERE created_at>=p_start_at AND created_at<p_end_at;
      IF v_count=0 THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','SQL_DATA_NOT_AVAILABLE'
        );
      END IF;
      v_value := round(100.0*v_count2/v_count,2);

    WHEN 'opportunity_to_won_rate' THEN
      SELECT count(*) FILTER (WHERE opportunity_at IS NOT NULL),
             count(*) FILTER (
               WHERE opportunity_at IS NOT NULL AND won_at IS NOT NULL
             )
      INTO v_count,v_count2
      FROM governance.filtered_funnel_records_v2(p_scope_values,p_filters)
      WHERE created_at>=p_start_at AND created_at<p_end_at;
      IF v_count=0 THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','OPPORTUNITY_DATA_NOT_AVAILABLE'
        );
      END IF;
      v_value := round(100.0*v_count2/v_count,2);

    WHEN 'speed_to_lead_hours' THEN
      SELECT count(*),count(first_response_at),
             round(avg(extract(epoch FROM (first_response_at-created_at))/3600.0),2)
      INTO v_count,v_populated,v_value
      FROM governance.filtered_funnel_records_v2(p_scope_values,p_filters)
      WHERE created_at>=p_start_at AND created_at<p_end_at;
      IF v_count=0 THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','FUNNEL_DATA_NOT_AVAILABLE'
        );
      ELSIF v_populated<v_count THEN
        RETURN jsonb_build_object(
          'status','unavailable',
          'reason','FIRST_RESPONSE_COVERAGE_INCOMPLETE',
          'eligible_records',v_count,
          'populated_records',v_populated
        );
      END IF;

    ELSE
      RETURN jsonb_build_object(
        'status','rejected','reason','QUERY_NOT_EXECUTABLE'
      );
  END CASE;

  RETURN jsonb_build_object(
    'status','approved','result_type','scalar','value',v_value
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.compute_activity_metric_v2(
  p_kpi_key text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_dimension text,
  p_scope_values text[],
  p_filters jsonb,
  p_max_rows integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
DECLARE
  v_count bigint;
  v_count2 bigint;
  v_value numeric;
  v_rows jsonb;
  v_as_of timestamptz := LEAST(p_end_at,now());
BEGIN
  IF p_dimension IS NOT NULL THEN
    IF p_dimension<>'sales_rep' THEN
      RETURN jsonb_build_object(
        'status','rejected','reason','BREAKDOWN_QUERY_NOT_EXECUTABLE'
      );
    END IF;

    SELECT COALESCE(jsonb_agg(
      jsonb_build_object('dimension_value',dimension_value,'value',metric_value)
      ORDER BY metric_value DESC NULLS LAST,dimension_value
    ),'[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT COALESCE(NULLIF(btrim(sales_rep),''),'Unassigned') AS dimension_value,
        CASE p_kpi_key
          WHEN 'follow_up_sla_compliance' THEN
            round(
              100.0*count(*) FILTER (
                WHERE completed_at IS NOT NULL AND completed_at<=due_at
              )/NULLIF(count(*),0),
              2
            )
          WHEN 'overdue_followups' THEN
            count(*) FILTER (
              WHERE due_at<v_as_of
                AND (completed_at IS NULL OR completed_at>due_at)
            )::numeric
          ELSE NULL::numeric
        END AS metric_value
      FROM governance.filtered_activities_v2(p_scope_values,p_filters)
      WHERE due_at>=p_start_at AND due_at<p_end_at
      GROUP BY sales_rep
      ORDER BY metric_value DESC NULLS LAST,dimension_value
      LIMIT GREATEST(1,LEAST(COALESCE(p_max_rows,100),1000))
    ) grouped_metrics;

    RETURN jsonb_build_object(
      'status','approved','result_type','breakdown',
      'dimension_key',p_dimension,'rows',v_rows
    );
  END IF;

  CASE p_kpi_key
    WHEN 'follow_up_sla_compliance' THEN
      SELECT count(*),
             count(*) FILTER (
               WHERE completed_at IS NOT NULL AND completed_at<=due_at
             )
      INTO v_count,v_count2
      FROM governance.filtered_activities_v2(p_scope_values,p_filters)
      WHERE due_at>=p_start_at AND due_at<p_end_at;

      IF v_count=0 THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','ACTIVITY_SLA_DATA_NOT_AVAILABLE'
        );
      END IF;
      v_value := round(100.0*v_count2/v_count,2);

    WHEN 'overdue_followups' THEN
      SELECT count(*)::numeric
      INTO v_value
      FROM governance.filtered_activities_v2(p_scope_values,p_filters)
      WHERE due_at>=p_start_at AND due_at<p_end_at
        AND due_at<v_as_of
        AND (completed_at IS NULL OR completed_at>due_at);

    ELSE
      RETURN jsonb_build_object(
        'status','rejected','reason','QUERY_NOT_EXECUTABLE'
      );
  END CASE;

  RETURN jsonb_build_object(
    'status','approved','result_type','scalar','value',v_value
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.compute_subscription_metric_v2(
  p_kpi_key text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_dimension text,
  p_scope_values text[],
  p_filters jsonb,
  p_max_rows integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
DECLARE
  v_value numeric;
  v_starting numeric;
  v_change numeric;
  v_rows jsonb;
BEGIN
  IF p_dimension IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object('dimension_value',dimension_value,'value',metric_value)
      ORDER BY metric_value DESC NULLS LAST,dimension_value
    ),'[]'::jsonb)
    INTO v_rows
    FROM (
      WITH base AS (
        SELECT
          CASE p_dimension
            WHEN 'sales_rep' THEN COALESCE(NULLIF(btrim(sales_rep),''),'Unassigned')
            WHEN 'segment' THEN COALESCE(NULLIF(btrim(segment),''),'Unassigned')
            WHEN 'region' THEN COALESCE(NULLIF(btrim(region),''),'Unassigned')
            WHEN 'industry' THEN COALESCE(NULLIF(btrim(industry),''),'Unassigned')
            ELSE NULL
          END AS dimension_value,
          s.*
        FROM governance.filtered_subscription_events_v2(p_scope_values,p_filters) s
      ),
      agg AS (
        SELECT dimension_value,
          COALESCE(sum(mrr_delta) FILTER (WHERE occurred_at<p_start_at),0) AS starting_mrr,
          COALESCE(sum(mrr_delta) FILTER (WHERE occurred_at<p_end_at),0) AS current_mrr,
          COALESCE(sum(mrr_delta) FILTER (
            WHERE event_type='expansion'
              AND occurred_at>=p_start_at AND occurred_at<p_end_at
          ),0) AS expansion_mrr,
          COALESCE(abs(sum(mrr_delta) FILTER (
            WHERE event_type='churn'
              AND occurred_at>=p_start_at AND occurred_at<p_end_at
          )),0) AS churned_mrr,
          COALESCE(sum(mrr_delta) FILTER (
            WHERE occurred_at>=p_start_at AND occurred_at<p_end_at
              AND event_type IN ('expansion','contraction','churn')
          ),0) AS net_change,
          COALESCE(sum(mrr_delta) FILTER (
            WHERE occurred_at>=p_start_at AND occurred_at<p_end_at
              AND event_type IN ('contraction','churn')
          ),0) AS gross_change
        FROM base
        WHERE dimension_value IS NOT NULL
        GROUP BY dimension_value
      )
      SELECT dimension_value,
        CASE p_kpi_key
          WHEN 'current_mrr' THEN current_mrr
          WHEN 'current_arr' THEN current_mrr*12
          WHEN 'expansion_mrr' THEN expansion_mrr
          WHEN 'churned_mrr' THEN churned_mrr
          WHEN 'net_revenue_retention' THEN
            round(100.0*(starting_mrr+net_change)/NULLIF(starting_mrr,0),2)
          WHEN 'gross_revenue_retention' THEN
            greatest(
              0,
              round(100.0*(starting_mrr+gross_change)/NULLIF(starting_mrr,0),2)
            )
          ELSE NULL::numeric
        END AS metric_value
      FROM agg
      WHERE p_kpi_key NOT IN ('net_revenue_retention','gross_revenue_retention')
         OR starting_mrr>0
      ORDER BY metric_value DESC NULLS LAST,dimension_value
      LIMIT GREATEST(1,LEAST(COALESCE(p_max_rows,100),1000))
    ) grouped_metrics;

    RETURN jsonb_build_object(
      'status','approved','result_type','breakdown',
      'dimension_key',p_dimension,'rows',v_rows
    );
  END IF;

  CASE p_kpi_key
    WHEN 'current_mrr' THEN
      SELECT COALESCE(sum(mrr_delta),0)
      INTO v_value
      FROM governance.filtered_subscription_events_v2(p_scope_values,p_filters)
      WHERE occurred_at<p_end_at;

    WHEN 'current_arr' THEN
      SELECT COALESCE(sum(mrr_delta),0)*12
      INTO v_value
      FROM governance.filtered_subscription_events_v2(p_scope_values,p_filters)
      WHERE occurred_at<p_end_at;

    WHEN 'expansion_mrr' THEN
      SELECT COALESCE(sum(mrr_delta),0)
      INTO v_value
      FROM governance.filtered_subscription_events_v2(p_scope_values,p_filters)
      WHERE event_type='expansion'
        AND occurred_at>=p_start_at AND occurred_at<p_end_at;

    WHEN 'churned_mrr' THEN
      SELECT COALESCE(abs(sum(mrr_delta)),0)
      INTO v_value
      FROM governance.filtered_subscription_events_v2(p_scope_values,p_filters)
      WHERE event_type='churn'
        AND occurred_at>=p_start_at AND occurred_at<p_end_at;

    WHEN 'net_revenue_retention' THEN
      SELECT COALESCE(sum(mrr_delta),0)
      INTO v_starting
      FROM governance.filtered_subscription_events_v2(p_scope_values,p_filters)
      WHERE occurred_at<p_start_at;

      IF v_starting<=0 THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','STARTING_MRR_NOT_AVAILABLE'
        );
      END IF;

      SELECT COALESCE(sum(mrr_delta),0)
      INTO v_change
      FROM governance.filtered_subscription_events_v2(p_scope_values,p_filters)
      WHERE occurred_at>=p_start_at AND occurred_at<p_end_at
        AND event_type IN ('expansion','contraction','churn');

      v_value := round(100.0*(v_starting+v_change)/v_starting,2);

    WHEN 'gross_revenue_retention' THEN
      SELECT COALESCE(sum(mrr_delta),0)
      INTO v_starting
      FROM governance.filtered_subscription_events_v2(p_scope_values,p_filters)
      WHERE occurred_at<p_start_at;

      IF v_starting<=0 THEN
        RETURN jsonb_build_object(
          'status','unavailable','reason','STARTING_MRR_NOT_AVAILABLE'
        );
      END IF;

      SELECT COALESCE(sum(mrr_delta),0)
      INTO v_change
      FROM governance.filtered_subscription_events_v2(p_scope_values,p_filters)
      WHERE occurred_at>=p_start_at AND occurred_at<p_end_at
        AND event_type IN ('contraction','churn');

      v_value := greatest(0,round(100.0*(v_starting+v_change)/v_starting,2));

    ELSE
      RETURN jsonb_build_object(
        'status','rejected','reason','QUERY_NOT_EXECUTABLE'
      );
  END CASE;

  RETURN jsonb_build_object(
    'status','approved','result_type','scalar','value',v_value
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.compute_target_metric_v2(
  p_kpi_key text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_dimension text,
  p_scope_values text[],
  p_filters jsonb,
  p_max_rows integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
DECLARE
  v_value numeric;
  v_num numeric;
  v_den numeric;
  v_rows jsonb;
  v_timezone text;
  v_period_start_date date;
  v_period_end_date date;
BEGIN
  SELECT timezone INTO v_timezone
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;
  v_period_start_date := timezone(v_timezone,p_start_at)::date;
  v_period_end_date := (timezone(v_timezone,p_end_at)-interval '1 second')::date;

  IF p_dimension IS NOT NULL AND p_dimension<>'sales_rep' THEN
    RETURN jsonb_build_object(
      'status','rejected','reason','BREAKDOWN_QUERY_NOT_EXECUTABLE'
    );
  END IF;

  IF p_dimension='sales_rep' THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object('dimension_value',sales_rep,'value',metric_value)
      ORDER BY metric_value DESC NULLS LAST,sales_rep
    ),'[]'::jsonb)
    INTO v_rows
    FROM (
      WITH reps AS (
        SELECT DISTINCT sales_rep
        FROM reporting.revenue_targets
        WHERE active
          AND target_type='revenue_quota'
          AND period_start<=v_period_start_date
          AND period_end>=v_period_end_date
          AND sales_rep IS NOT NULL
          AND (cardinality(COALESCE(p_scope_values,'{}'::text[]))=0
               OR sales_rep=ANY(p_scope_values))
          AND (
            cardinality(governance.filter_values_v2(p_filters,'sales_rep'))=0
            OR sales_rep=ANY(governance.filter_values_v2(p_filters,'sales_rep'))
          )
      ),
      target_by_rep AS (
        SELECT t.sales_rep,sum(t.target_amount) AS target_amount
        FROM reporting.revenue_targets t
        JOIN reps r USING (sales_rep)
        WHERE t.active
          AND t.target_type='revenue_quota'
          AND t.period_start<=v_period_start_date
          AND t.period_end>=v_period_end_date
        GROUP BY t.sales_rep
      ),
      deal_by_rep AS (
        SELECT d.sales_rep,
          COALESCE(sum(d.amount) FILTER (
            WHERE d.stage_category='open'
              AND d.expected_close_date>=p_start_at
              AND d.expected_close_date<p_end_at
          ),0) AS open_pipeline,
          COALESCE(sum(d.amount) FILTER (
            WHERE d.stage_category='won'
              AND d.closed_at>=p_start_at
              AND d.closed_at<p_end_at
          ),0) AS won_revenue
        FROM governance.filtered_deals_v2(p_scope_values,p_filters) d
        JOIN reps r USING (sales_rep)
        GROUP BY d.sales_rep
      )
      SELECT t.sales_rep,
        CASE p_kpi_key
          WHEN 'pipeline_coverage_ratio' THEN
            round(COALESCE(d.open_pipeline,0)/NULLIF(t.target_amount,0),2)
          WHEN 'quota_attainment' THEN
            round(100.0*COALESCE(d.won_revenue,0)/NULLIF(t.target_amount,0),2)
          ELSE NULL::numeric
        END AS metric_value
      FROM target_by_rep t
      LEFT JOIN deal_by_rep d USING (sales_rep)
      WHERE t.target_amount>0
      ORDER BY metric_value DESC NULLS LAST,t.sales_rep
      LIMIT GREATEST(1,LEAST(COALESCE(p_max_rows,100),1000))
    ) q;

    RETURN jsonb_build_object(
      'status','approved','result_type','breakdown',
      'dimension_key','sales_rep','rows',v_rows
    );
  END IF;

  SELECT sum(target_amount)
  INTO v_den
  FROM reporting.revenue_targets
  WHERE active
    AND target_type='revenue_quota'
    AND period_start<=v_period_start_date
    AND period_end>=v_period_end_date
    AND (cardinality(COALESCE(p_scope_values,'{}'::text[]))=0
         OR sales_rep=ANY(p_scope_values))
    AND (
      cardinality(governance.filter_values_v2(p_filters,'sales_rep'))=0
      OR sales_rep=ANY(governance.filter_values_v2(p_filters,'sales_rep'))
    );

  IF v_den IS NULL OR v_den=0 THEN
    RETURN jsonb_build_object(
      'status','unavailable','reason','REVENUE_TARGET_NOT_AVAILABLE'
    );
  END IF;

  IF p_kpi_key='pipeline_coverage_ratio' THEN
    SELECT COALESCE(sum(amount),0)
    INTO v_num
    FROM governance.filtered_deals_v2(p_scope_values,p_filters)
    WHERE stage_category='open'
      AND expected_close_date>=p_start_at AND expected_close_date<p_end_at;
    v_value := round(v_num/v_den,2);

  ELSIF p_kpi_key='quota_attainment' THEN
    SELECT COALESCE(sum(amount),0)
    INTO v_num
    FROM governance.filtered_deals_v2(p_scope_values,p_filters)
    WHERE stage_category='won'
      AND closed_at>=p_start_at AND closed_at<p_end_at;
    v_value := round(100.0*v_num/v_den,2);

  ELSE
    RETURN jsonb_build_object(
      'status','rejected','reason','QUERY_NOT_EXECUTABLE'
    );
  END IF;

  RETURN jsonb_build_object(
    'status','approved','result_type','scalar','value',v_value
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.compute_forecast_metric_v2(
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_dimension text,
  p_scope_values text[],
  p_filters jsonb,
  p_max_rows integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
DECLARE
  v_forecast numeric;
  v_actual numeric;
  v_count bigint;
  v_populated bigint;
  v_value numeric;
  v_rows jsonb;
  v_timezone text;
  v_period_start_date date;
  v_period_end_date date;
BEGIN
  SELECT timezone INTO v_timezone
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;
  v_period_start_date := timezone(v_timezone,p_start_at)::date;
  v_period_end_date := (timezone(v_timezone,p_end_at)-interval '1 second')::date;

  IF p_dimension IS NOT NULL AND p_dimension<>'sales_rep' THEN
    RETURN jsonb_build_object(
      'status','rejected','reason','BREAKDOWN_QUERY_NOT_EXECUTABLE'
    );
  END IF;

  IF p_dimension='sales_rep' THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object('dimension_value',sales_rep,'value',metric_value)
      ORDER BY metric_value DESC NULLS LAST,sales_rep
    ),'[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT COALESCE(NULLIF(btrim(sales_rep),''),'Unassigned') AS sales_rep,
        greatest(
          0,
          round(
            100.0*(
              1-abs(sum(forecast_amount)-sum(actual_amount))
                / NULLIF(abs(sum(actual_amount)),0)
            ),
            2
          )
        ) AS metric_value
      FROM reporting.forecast_snapshots
      WHERE period_start=v_period_start_date
        AND period_end=v_period_end_date
        AND actual_amount IS NOT NULL
        AND (cardinality(COALESCE(p_scope_values,'{}'::text[]))=0
             OR sales_rep=ANY(p_scope_values))
        AND (
          cardinality(governance.filter_values_v2(p_filters,'sales_rep'))=0
          OR sales_rep=ANY(governance.filter_values_v2(p_filters,'sales_rep'))
        )
      GROUP BY sales_rep
      HAVING sum(actual_amount)<>0
      ORDER BY metric_value DESC NULLS LAST,sales_rep
      LIMIT GREATEST(1,LEAST(COALESCE(p_max_rows,100),1000))
    ) q;

    RETURN jsonb_build_object(
      'status','approved','result_type','breakdown',
      'dimension_key','sales_rep','rows',v_rows
    );
  END IF;

  SELECT sum(forecast_amount),sum(actual_amount),count(*),count(actual_amount)
  INTO v_forecast,v_actual,v_count,v_populated
  FROM reporting.forecast_snapshots
  WHERE period_start=v_period_start_date
    AND period_end=v_period_end_date
    AND (cardinality(COALESCE(p_scope_values,'{}'::text[]))=0
         OR sales_rep=ANY(p_scope_values))
    AND (
      cardinality(governance.filter_values_v2(p_filters,'sales_rep'))=0
      OR sales_rep=ANY(governance.filter_values_v2(p_filters,'sales_rep'))
    );

  IF v_count=0 OR v_populated<v_count OR COALESCE(v_actual,0)=0 THEN
    RETURN jsonb_build_object(
      'status','unavailable','reason','FORECAST_ACTUALS_NOT_AVAILABLE'
    );
  END IF;

  v_value := greatest(
    0,
    round(100.0*(1-abs(v_forecast-v_actual)/abs(v_actual)),2)
  );

  RETURN jsonb_build_object(
    'status','approved','result_type','scalar','value',v_value
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.execute_authorized_period_v2(
  p_principal_key text,
  p_kpi_key text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_dimensions jsonb DEFAULT '[]'::jsonb,
  p_filters jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
DECLARE
  v_dimensions text[] := '{}'::text[];
  v_dimension text;
  v_filter_keys text[] := '{}'::text[];
  v_requested_filters text[] := ARRAY['date_range']::text[];
  v_filter_error text;
  v_auth record;
  v_semantics record;
  v_domains jsonb;
  v_result jsonb;
  v_scope_values text[] := '{}'::text[];
  v_currency text;
  v_result_limit integer;
BEGIN
  IF p_start_at IS NULL OR p_end_at IS NULL OR p_start_at>=p_end_at THEN
    RETURN jsonb_build_object(
      'status','rejected','reason','INVALID_DATE_RANGE'
    );
  END IF;

  IF p_dimensions IS NULL THEN
    p_dimensions := '[]'::jsonb;
  END IF;

  IF jsonb_typeof(p_dimensions)<>'array'
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(p_dimensions) e(value)
       WHERE jsonb_typeof(e.value)<>'string'
     ) THEN
    RETURN jsonb_build_object(
      'status','rejected','reason','DIMENSIONS_INVALID'
    );
  END IF;

  SELECT COALESCE(
    array_agg(DISTINCT btrim(value) ORDER BY btrim(value)),
    '{}'::text[]
  )
  INTO v_dimensions
  FROM jsonb_array_elements_text(p_dimensions) e(value);

  IF cardinality(v_dimensions)>1 THEN
    RETURN jsonb_build_object(
      'status','rejected','reason','MULTI_DIMENSION_NOT_SUPPORTED'
    );
  END IF;

  IF cardinality(v_dimensions)=1 THEN
    v_dimension := v_dimensions[1];
  END IF;

  v_filter_error := governance.validate_report_filters_v2(p_filters);
  IF v_filter_error IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status','rejected','reason',v_filter_error
    );
  END IF;

  SELECT COALESCE(array_agg(key ORDER BY key),'{}'::text[])
  INTO v_filter_keys
  FROM jsonb_object_keys(COALESCE(p_filters,'{}'::jsonb)) key;

  IF cardinality(v_filter_keys)>0 THEN
    v_requested_filters := v_requested_filters || v_filter_keys;
  END IF;

  SELECT *
  INTO v_auth
  FROM governance.authorize_kpi_request(
    p_principal_key,p_kpi_key,v_dimensions,v_requested_filters
  );

  IF NOT FOUND OR v_auth.allowed IS DISTINCT FROM true THEN
    RETURN jsonb_build_object(
      'status','rejected',
      'reason',COALESCE(v_auth.reason,'AUTHORIZATION_FAILED')
    );
  END IF;

  SELECT *
  INTO v_semantics
  FROM governance.resolve_kpi_semantics(p_kpi_key,NULL);

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status','rejected','reason','KPI_NOT_APPROVED'
    );
  END IF;

  v_domains := governance.metric_data_domains_ready_v2(p_kpi_key);
  IF COALESCE((v_domains->>'ready')::boolean,false) IS DISTINCT FROM true THEN
    RETURN jsonb_build_object(
      'status','unavailable',
      'reason','DATA_DOMAIN_NOT_READY',
      'missing_domains',COALESCE(v_domains->'missing_domains','[]'::jsonb)
    );
  END IF;

  v_scope_values := COALESCE(v_auth.scope_values,'{}'::text[]);
  v_result_limit := CASE
    WHEN v_dimension IS NULL
      THEN LEAST(v_auth.max_rows,v_semantics.maximum_rows)
    ELSE LEAST(v_auth.max_rows,1000)
  END;

  SELECT trim(both FROM currency_code::text)
  INTO v_currency
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;

  IF p_kpi_key IN ('pipeline_coverage_ratio','quota_attainment') THEN
    v_result := governance.compute_target_metric_v2(
      p_kpi_key,p_start_at,p_end_at,v_dimension,
      v_scope_values,p_filters,
      v_result_limit
    );

  ELSIF p_kpi_key IN (
    'lead_to_mql_rate','mql_to_sql_rate','sql_to_opportunity_rate',
    'opportunity_to_won_rate','speed_to_lead_hours'
  ) THEN
    v_result := governance.compute_funnel_metric_v2(
      p_kpi_key,p_start_at,p_end_at,v_dimension,
      v_scope_values,p_filters,
      v_result_limit
    );

  ELSIF p_kpi_key IN (
    'follow_up_sla_compliance','overdue_followups'
  ) THEN
    v_result := governance.compute_activity_metric_v2(
      p_kpi_key,p_start_at,p_end_at,v_dimension,
      v_scope_values,p_filters,
      v_result_limit
    );

  ELSIF p_kpi_key IN (
    'current_mrr','current_arr','expansion_mrr','churned_mrr',
    'net_revenue_retention','gross_revenue_retention'
  ) THEN
    v_result := governance.compute_subscription_metric_v2(
      p_kpi_key,p_start_at,p_end_at,v_dimension,
      v_scope_values,p_filters,
      v_result_limit
    );

  ELSIF p_kpi_key='forecast_accuracy' THEN
    v_result := governance.compute_forecast_metric_v2(
      p_start_at,p_end_at,v_dimension,
      v_scope_values,p_filters,
      v_result_limit
    );

  ELSE
    v_result := governance.compute_deal_metric_v2(
      p_kpi_key,p_start_at,p_end_at,v_dimension,
      v_scope_values,p_filters,
      v_result_limit
    );
  END IF;

  IF v_result->>'status'<>'approved' THEN
    RETURN v_result;
  END IF;

  RETURN v_result || jsonb_build_object(
    'kpi_key',p_kpi_key,
    'query_key',v_semantics.query_key,
    'unit',v_semantics.unit,
    'currency_code',v_currency,
    'data_scope',v_auth.data_scope
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.execute_agent_report_request_v2(
  p_principal_key text,
  p_kpi_key text,
  p_period_key text,
  p_mode text DEFAULT 'metric_report',
  p_dimensions jsonb DEFAULT '[]'::jsonb,
  p_filters jsonb DEFAULT '{}'::jsonb,
  p_reference timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance
AS $$
DECLARE
  v_period record;
  v_current jsonb;
  v_previous jsonb;
  v_compare boolean;
  v_value numeric;
  v_previous_value numeric;
  v_delta numeric;
  v_percent_change numeric;
  v_direction text;
  v_diagnostics jsonb := '{}'::jsonb;
  v_dimension text;
  v_dim_current jsonb;
  v_dim_previous jsonb;
BEGIN
  IF p_mode NOT IN (
    'metric_report','trend_report','comparison_report',
    'breakdown_report','diagnostic_report'
  ) THEN
    RETURN jsonb_build_object(
      'status','rejected','reason','REPORT_MODE_NOT_SUPPORTED'
    );
  END IF;

  SELECT *
  INTO v_period
  FROM governance.resolve_relative_period(p_period_key,p_reference);

  IF p_mode='diagnostic_report' AND p_kpi_key<>'open_pipeline' THEN
    RETURN jsonb_build_object(
      'status','rejected',
      'reason','DIAGNOSTIC_REPORT_NOT_SUPPORTED_FOR_KPI'
    );
  END IF;

  v_current := governance.execute_authorized_period_v2(
    p_principal_key,
    p_kpi_key,
    v_period.start_at,
    v_period.end_at,
    CASE
      WHEN p_mode='diagnostic_report' THEN '[]'::jsonb
      ELSE COALESCE(p_dimensions,'[]'::jsonb)
    END,
    COALESCE(p_filters,'{}'::jsonb)
  );

  IF v_current->>'status'<>'approved' THEN
    RETURN v_current || jsonb_build_object(
      'kpi_key',p_kpi_key,
      'period_key',p_period_key
    );
  END IF;

  v_compare := p_mode IN (
    'trend_report','comparison_report','diagnostic_report'
  );

  IF v_compare THEN
    v_previous := governance.execute_authorized_period_v2(
      p_principal_key,
      p_kpi_key,
      v_period.previous_start_at,
      v_period.previous_end_at,
      CASE
        WHEN p_mode='diagnostic_report' THEN '[]'::jsonb
        ELSE COALESCE(p_dimensions,'[]'::jsonb)
      END,
      COALESCE(p_filters,'{}'::jsonb)
    );

    IF v_previous->>'status'<>'approved' THEN
      RETURN v_previous || jsonb_build_object(
        'kpi_key',p_kpi_key,
        'period_key',p_period_key,
        'comparison_stage','previous_period'
      );
    END IF;

    IF v_current->>'result_type'='scalar'
       AND v_previous->>'result_type'='scalar' THEN
      v_value := (v_current->>'value')::numeric;
      v_previous_value := (v_previous->>'value')::numeric;
      v_delta := v_value-v_previous_value;

      IF v_previous_value<>0 THEN
        v_percent_change := round(
          100.0*v_delta/abs(v_previous_value),
          2
        );
      END IF;

      v_direction := CASE
        WHEN v_delta>0 THEN 'up'
        WHEN v_delta<0 THEN 'down'
        ELSE 'flat'
      END;
    END IF;
  END IF;

  IF p_mode='diagnostic_report' THEN
    FOREACH v_dimension IN ARRAY ARRAY[
      'sales_rep','deal_stage','lead_source',
      'segment','region','campaign'
    ]
    LOOP
      v_dim_current := governance.execute_authorized_period_v2(
        p_principal_key,
        p_kpi_key,
        v_period.start_at,
        v_period.end_at,
        to_jsonb(ARRAY[v_dimension]::text[]),
        COALESCE(p_filters,'{}'::jsonb)
      );

      v_dim_previous := governance.execute_authorized_period_v2(
        p_principal_key,
        p_kpi_key,
        v_period.previous_start_at,
        v_period.previous_end_at,
        to_jsonb(ARRAY[v_dimension]::text[]),
        COALESCE(p_filters,'{}'::jsonb)
      );

      IF v_dim_current->>'status'='approved'
         AND v_dim_previous->>'status'='approved' THEN
        v_diagnostics := v_diagnostics || jsonb_build_object(
          v_dimension,
          jsonb_build_object(
            'current_rows',v_dim_current->'rows',
            'previous_rows',v_dim_previous->'rows'
          )
        );
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'status','approved',
    'report_type',CASE
      WHEN p_mode='diagnostic_report' THEN 'diagnostic'
      WHEN v_current->>'result_type'='breakdown' THEN 'breakdown'
      ELSE 'scalar'
    END,
    'kpi_key',p_kpi_key,
    'query_key',v_current->>'query_key',
    'unit',v_current->>'unit',
    'currency_code',v_current->>'currency_code',
    'mode',p_mode,
    'reporting_timezone',v_period.reporting_timezone,
    'data_scope',v_current->>'data_scope',
    'dimensions',COALESCE(p_dimensions,'[]'::jsonb),
    'current_period',jsonb_build_object(
      'period_key',p_period_key,
      'start_at',v_period.start_at,
      'end_at',v_period.end_at,
      'value',CASE
        WHEN v_current->>'result_type'='scalar'
          THEN v_current->'value'
        ELSE NULL
      END,
      'rows',CASE
        WHEN v_current->>'result_type'='breakdown'
          THEN v_current->'rows'
        ELSE NULL
      END
    ),
    'previous_period',CASE
      WHEN v_compare THEN jsonb_build_object(
        'start_at',v_period.previous_start_at,
        'end_at',v_period.previous_end_at,
        'value',CASE
          WHEN v_previous->>'result_type'='scalar'
            THEN v_previous->'value'
          ELSE NULL
        END,
        'rows',CASE
          WHEN v_previous->>'result_type'='breakdown'
            THEN v_previous->'rows'
          ELSE NULL
        END
      )
      ELSE NULL
    END,
    'analysis',CASE
      WHEN v_compare
       AND v_current->>'result_type'='scalar'
       AND v_previous->>'result_type'='scalar'
      THEN jsonb_build_object(
        'delta',v_delta,
        'percent_change',v_percent_change,
        'direction',v_direction
      )
      ELSE NULL
    END,
    'diagnostics',CASE
      WHEN p_mode='diagnostic_report' THEN v_diagnostics
      ELSE NULL
    END
  );
END;
$$;

REVOKE ALL ON FUNCTION governance.compute_deal_metric_v2(
  text,timestamptz,timestamptz,text,text[],jsonb,integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.compute_funnel_metric_v2(
  text,timestamptz,timestamptz,text,text[],jsonb,integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.compute_activity_metric_v2(
  text,timestamptz,timestamptz,text,text[],jsonb,integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.compute_subscription_metric_v2(
  text,timestamptz,timestamptz,text,text[],jsonb,integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.compute_target_metric_v2(
  text,timestamptz,timestamptz,text,text[],jsonb,integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.compute_forecast_metric_v2(
  timestamptz,timestamptz,text,text[],jsonb,integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.execute_authorized_period_v2(
  text,text,timestamptz,timestamptz,jsonb,jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.execute_agent_report_request_v2(
  text,text,text,text,jsonb,jsonb,timestamptz
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION governance.compute_deal_metric_v2(
  text,timestamptz,timestamptz,text,text[],jsonb,integer
) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.compute_funnel_metric_v2(
  text,timestamptz,timestamptz,text,text[],jsonb,integer
) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.compute_activity_metric_v2(
  text,timestamptz,timestamptz,text,text[],jsonb,integer
) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.compute_subscription_metric_v2(
  text,timestamptz,timestamptz,text,text[],jsonb,integer
) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.compute_target_metric_v2(
  text,timestamptz,timestamptz,text,text[],jsonb,integer
) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.compute_forecast_metric_v2(
  timestamptz,timestamptz,text,text[],jsonb,integer
) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.execute_authorized_period_v2(
  text,text,timestamptz,timestamptz,jsonb,jsonb
) TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.execute_agent_report_request_v2(
  text,text,text,text,jsonb,jsonb,timestamptz
) TO revint_governance_ro;

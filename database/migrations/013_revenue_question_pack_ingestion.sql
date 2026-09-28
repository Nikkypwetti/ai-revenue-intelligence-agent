\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION ingestion.ingest_deal_from_source(
  p_connector_key text,
  p_source_record_id text,
  p_source_payload jsonb
)
RETURNS TABLE(deal_id bigint, ingestion_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, governance, reporting, ingestion
AS $$
DECLARE
  v_connector governance.connector_registry%ROWTYPE;
  v_business_currency text;
  v_deal_name text;
  v_amount numeric(18,2);
  v_currency_code text;
  v_stage_name text;
  v_stage_category text;
  v_sales_rep text;
  v_lead_source text;
  v_created_at timestamptz;
  v_expected_close_date timestamptz;
  v_closed_at timestamptz;
  v_source_updated_at timestamptz;
  v_probability_percent numeric(5,2);
  v_forecast_category text;
  v_account_key text;
  v_segment text;
  v_region text;
  v_industry text;
  v_campaign text;
  v_qualified_at timestamptz;
  v_opportunity_at timestamptz;
  v_proposal_sent_at timestamptz;
  v_stage_entered_at timestamptz;
  v_last_activity_at timestamptz;
  v_next_activity_at timestamptz;
  v_first_response_at timestamptz;
  v_sla_due_at timestamptz;
  v_lost_reason text;
  v_annual_contract_value numeric(18,2);
  v_monthly_recurring_revenue numeric(18,2);
  v_list_amount numeric(18,2);
  v_discount_percent numeric(6,2);
BEGIN
  IF jsonb_typeof(p_source_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'SOURCE_PAYLOAD_MUST_BE_OBJECT';
  END IF;

  IF NULLIF(btrim(COALESCE(p_source_record_id,'')),'') IS NULL
     OR length(btrim(p_source_record_id))>200 THEN
    RAISE EXCEPTION 'SOURCE_RECORD_ID_INVALID';
  END IF;

  SELECT *
  INTO v_connector
  FROM governance.connector_registry
  WHERE connector_key=p_connector_key
    AND active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONNECTOR_NOT_ACTIVE: %',p_connector_key;
  END IF;

  IF v_connector.object_type<>'deal' OR v_connector.contract_version<>1 THEN
    RAISE EXCEPTION
      'CONNECTOR_CONTRACT_NOT_SUPPORTED: % v%',
      v_connector.object_type,v_connector.contract_version;
  END IF;

  SELECT trim(both FROM currency_code::text)
  INTO v_business_currency
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;

  v_deal_name := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'deal_name');
  v_amount := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'amount'),'')::numeric(18,2);
  v_currency_code := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'currency_code');
  v_stage_name := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'stage_name');
  v_stage_category := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'stage_category');
  v_sales_rep := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'sales_rep');
  v_lead_source := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'lead_source');
  v_created_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'created_at'),'')::timestamptz;
  v_expected_close_date := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'expected_close_date'),'')::timestamptz;
  v_closed_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'closed_at'),'')::timestamptz;
  v_source_updated_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'source_updated_at'),'')::timestamptz;

  v_probability_percent := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'probability_percent'),'')::numeric(5,2);
  v_forecast_category := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'forecast_category');
  v_account_key := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'account_key');
  v_segment := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'segment');
  v_region := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'region');
  v_industry := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'industry');
  v_campaign := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'campaign');
  v_qualified_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'qualified_at'),'')::timestamptz;
  v_opportunity_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'opportunity_at'),'')::timestamptz;
  v_proposal_sent_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'proposal_sent_at'),'')::timestamptz;
  v_stage_entered_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'stage_entered_at'),'')::timestamptz;
  v_last_activity_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'last_activity_at'),'')::timestamptz;
  v_next_activity_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'next_activity_at'),'')::timestamptz;
  v_first_response_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'first_response_at'),'')::timestamptz;
  v_sla_due_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'sla_due_at'),'')::timestamptz;
  v_lost_reason := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'lost_reason');
  v_annual_contract_value := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'annual_contract_value'),'')::numeric(18,2);
  v_monthly_recurring_revenue := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'monthly_recurring_revenue'),'')::numeric(18,2);
  v_list_amount := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'list_amount'),'')::numeric(18,2);
  v_discount_percent := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'discount_percent'),'')::numeric(6,2);

  IF v_amount IS NULL OR v_amount<0 THEN
    RAISE EXCEPTION 'CANONICAL_AMOUNT_REQUIRED';
  END IF;

  IF v_currency_code IS NULL OR v_currency_code !~ '^[A-Z]{3}$'
     OR v_business_currency IS NULL OR v_currency_code<>v_business_currency THEN
    RAISE EXCEPTION
      'CURRENCY_NOT_SUPPORTED: source %, business %',
      COALESCE(v_currency_code,'missing'),COALESCE(v_business_currency,'missing');
  END IF;

  IF NULLIF(btrim(COALESCE(v_stage_name,'')),'') IS NULL THEN
    RAISE EXCEPTION 'CANONICAL_STAGE_NAME_REQUIRED';
  END IF;

  IF v_stage_category NOT IN ('open','won','lost') THEN
    RAISE EXCEPTION 'CANONICAL_STAGE_CATEGORY_INVALID';
  END IF;

  IF v_probability_percent IS NOT NULL
     AND (v_probability_percent<0 OR v_probability_percent>100) THEN
    RAISE EXCEPTION 'CANONICAL_PROBABILITY_INVALID';
  END IF;

  IF v_forecast_category IS NOT NULL
     AND v_forecast_category NOT IN (
       'pipeline','best_case','commit','closed','omitted'
     ) THEN
    RAISE EXCEPTION 'CANONICAL_FORECAST_CATEGORY_INVALID';
  END IF;

  IF v_stage_category='open' THEN
    v_closed_at := NULL;
  ELSIF v_closed_at IS NULL THEN
    RAISE EXCEPTION 'CLOSED_DEAL_REQUIRES_CLOSED_AT';
  END IF;

  IF v_stage_category<>'lost' THEN
    v_lost_reason := NULL;
  END IF;

  RETURN QUERY
  INSERT INTO reporting.deals(
    connector_key,source_record_id,deal_name,amount,currency_code,
    stage_name,stage_category,sales_rep,lead_source,created_at,
    expected_close_date,closed_at,source_updated_at,source_payload_hash,
    contract_version,ingested_at,probability_percent,forecast_category,
    account_key,segment,region,industry,campaign,qualified_at,opportunity_at,
    proposal_sent_at,stage_entered_at,last_activity_at,next_activity_at,
    first_response_at,sla_due_at,lost_reason,annual_contract_value,
    monthly_recurring_revenue,list_amount,discount_percent
  )
  VALUES(
    p_connector_key,btrim(p_source_record_id),v_deal_name,v_amount,
    v_currency_code,v_stage_name,v_stage_category,v_sales_rep,v_lead_source,
    v_created_at,v_expected_close_date,v_closed_at,v_source_updated_at,
    md5(p_source_payload::text),v_connector.contract_version,now(),
    v_probability_percent,v_forecast_category,v_account_key,v_segment,
    v_region,v_industry,v_campaign,v_qualified_at,v_opportunity_at,
    v_proposal_sent_at,v_stage_entered_at,v_last_activity_at,
    v_next_activity_at,v_first_response_at,v_sla_due_at,v_lost_reason,
    v_annual_contract_value,v_monthly_recurring_revenue,v_list_amount,
    v_discount_percent
  )
  ON CONFLICT(connector_key,source_record_id)
  DO UPDATE SET
    deal_name=EXCLUDED.deal_name,
    amount=EXCLUDED.amount,
    currency_code=EXCLUDED.currency_code,
    stage_name=EXCLUDED.stage_name,
    stage_category=EXCLUDED.stage_category,
    sales_rep=EXCLUDED.sales_rep,
    lead_source=EXCLUDED.lead_source,
    created_at=EXCLUDED.created_at,
    expected_close_date=EXCLUDED.expected_close_date,
    closed_at=EXCLUDED.closed_at,
    source_updated_at=EXCLUDED.source_updated_at,
    source_payload_hash=EXCLUDED.source_payload_hash,
    contract_version=EXCLUDED.contract_version,
    ingested_at=now(),
    probability_percent=EXCLUDED.probability_percent,
    forecast_category=EXCLUDED.forecast_category,
    account_key=EXCLUDED.account_key,
    segment=EXCLUDED.segment,
    region=EXCLUDED.region,
    industry=EXCLUDED.industry,
    campaign=EXCLUDED.campaign,
    qualified_at=EXCLUDED.qualified_at,
    opportunity_at=EXCLUDED.opportunity_at,
    proposal_sent_at=EXCLUDED.proposal_sent_at,
    stage_entered_at=EXCLUDED.stage_entered_at,
    last_activity_at=EXCLUDED.last_activity_at,
    next_activity_at=EXCLUDED.next_activity_at,
    first_response_at=EXCLUDED.first_response_at,
    sla_due_at=EXCLUDED.sla_due_at,
    lost_reason=EXCLUDED.lost_reason,
    annual_contract_value=EXCLUDED.annual_contract_value,
    monthly_recurring_revenue=EXCLUDED.monthly_recurring_revenue,
    list_amount=EXCLUDED.list_amount,
    discount_percent=EXCLUDED.discount_percent
  RETURNING reporting.deals.deal_id,'upserted'::text;
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.assert_connector_domain_v2(
  p_connector_key text,
  p_object_type text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance
AS $$
BEGIN
  IF NOT EXISTS(
    SELECT 1
    FROM governance.connector_registry
    WHERE connector_key=p_connector_key
      AND object_type=p_object_type
      AND contract_version=1
      AND active
  ) THEN
    RAISE EXCEPTION
      'CONNECTOR_DOMAIN_NOT_ACTIVE: %/%',
      p_connector_key,p_object_type;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.refresh_data_domain_status_v2(
  p_domain_key text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting
AS $$
DECLARE
  v_count bigint;
BEGIN
  CASE p_domain_key
    WHEN 'deals' THEN SELECT count(*) INTO v_count FROM reporting.deals;
    WHEN 'targets' THEN SELECT count(*) INTO v_count FROM reporting.revenue_targets;
    WHEN 'funnel' THEN SELECT count(*) INTO v_count FROM reporting.funnel_records;
    WHEN 'activities' THEN SELECT count(*) INTO v_count FROM reporting.activities;
    WHEN 'subscriptions' THEN SELECT count(*) INTO v_count FROM reporting.subscription_events;
    WHEN 'forecasts' THEN SELECT count(*) INTO v_count FROM reporting.forecast_snapshots;
    ELSE RAISE EXCEPTION 'DATA_DOMAIN_NOT_SUPPORTED: %',p_domain_key;
  END CASE;

  UPDATE governance.data_domain_status
  SET data_ready=(v_count>0),
      record_count=v_count,
      last_loaded_at=CASE WHEN v_count>0 THEN now() ELSE last_loaded_at END,
      updated_at=now()
  WHERE domain_key=p_domain_key AND active;
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.ingest_funnel_record_from_source_v2(
  p_connector_key text,
  p_source_record_id text,
  p_source_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting,ingestion
AS $$
DECLARE
  v_sales_rep text;
  v_lead_source text;
  v_campaign text;
  v_segment text;
  v_region text;
  v_industry text;
  v_created_at timestamptz;
  v_first_response_at timestamptz;
  v_mql_at timestamptz;
  v_sql_at timestamptz;
  v_opportunity_at timestamptz;
  v_won_at timestamptz;
  v_lost_at timestamptz;
  v_source_updated_at timestamptz;
BEGIN
  PERFORM ingestion.assert_connector_domain_v2(p_connector_key,'funnel');

  IF jsonb_typeof(p_source_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'SOURCE_PAYLOAD_MUST_BE_OBJECT';
  END IF;
  IF NULLIF(btrim(COALESCE(p_source_record_id,'')),'') IS NULL
     OR length(btrim(p_source_record_id))>200 THEN
    RAISE EXCEPTION 'SOURCE_RECORD_ID_INVALID';
  END IF;

  v_sales_rep := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'sales_rep');
  v_lead_source := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'lead_source');
  v_campaign := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'campaign');
  v_segment := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'segment');
  v_region := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'region');
  v_industry := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'industry');
  v_created_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'created_at'),'')::timestamptz;
  v_first_response_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'first_response_at'),'')::timestamptz;
  v_mql_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'mql_at'),'')::timestamptz;
  v_sql_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'sql_at'),'')::timestamptz;
  v_opportunity_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'opportunity_at'),'')::timestamptz;
  v_won_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'won_at'),'')::timestamptz;
  v_lost_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'lost_at'),'')::timestamptz;
  v_source_updated_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'source_updated_at'),'')::timestamptz;

  IF v_created_at IS NULL THEN
    RAISE EXCEPTION 'FUNNEL_CREATED_AT_REQUIRED';
  END IF;
  IF v_won_at IS NOT NULL AND v_lost_at IS NOT NULL THEN
    RAISE EXCEPTION 'FUNNEL_OUTCOME_CONFLICT';
  END IF;
  IF v_first_response_at IS NOT NULL AND v_first_response_at<v_created_at THEN
    RAISE EXCEPTION 'FUNNEL_FIRST_RESPONSE_BEFORE_CREATED';
  END IF;
  IF v_mql_at IS NOT NULL AND v_mql_at<v_created_at THEN
    RAISE EXCEPTION 'FUNNEL_MQL_BEFORE_CREATED';
  END IF;
  IF v_sql_at IS NOT NULL AND v_mql_at IS NOT NULL AND v_sql_at<v_mql_at THEN
    RAISE EXCEPTION 'FUNNEL_SQL_BEFORE_MQL';
  END IF;
  IF v_opportunity_at IS NOT NULL
     AND v_sql_at IS NOT NULL
     AND v_opportunity_at<v_sql_at THEN
    RAISE EXCEPTION 'FUNNEL_OPPORTUNITY_BEFORE_SQL';
  END IF;

  INSERT INTO reporting.funnel_records(
    connector_key,source_record_id,sales_rep,lead_source,campaign,segment,
    region,industry,created_at,first_response_at,mql_at,sql_at,
    opportunity_at,won_at,lost_at,source_updated_at,ingested_at
  )
  VALUES(
    p_connector_key,btrim(p_source_record_id),v_sales_rep,v_lead_source,
    v_campaign,v_segment,v_region,v_industry,v_created_at,
    v_first_response_at,v_mql_at,v_sql_at,v_opportunity_at,
    v_won_at,v_lost_at,v_source_updated_at,now()
  )
  ON CONFLICT(connector_key,source_record_id)
  DO UPDATE SET
    sales_rep=EXCLUDED.sales_rep,
    lead_source=EXCLUDED.lead_source,
    campaign=EXCLUDED.campaign,
    segment=EXCLUDED.segment,
    region=EXCLUDED.region,
    industry=EXCLUDED.industry,
    created_at=EXCLUDED.created_at,
    first_response_at=EXCLUDED.first_response_at,
    mql_at=EXCLUDED.mql_at,
    sql_at=EXCLUDED.sql_at,
    opportunity_at=EXCLUDED.opportunity_at,
    won_at=EXCLUDED.won_at,
    lost_at=EXCLUDED.lost_at,
    source_updated_at=EXCLUDED.source_updated_at,
    ingested_at=now();

  PERFORM ingestion.refresh_data_domain_status_v2('funnel');
  RETURN jsonb_build_object(
    'status','upserted','domain','funnel',
    'connector_key',p_connector_key,'source_record_id',btrim(p_source_record_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.ingest_activity_from_source_v2(
  p_connector_key text,
  p_source_record_id text,
  p_source_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting,ingestion
AS $$
DECLARE
  v_deal_source_record_id text;
  v_sales_rep text;
  v_activity_type text;
  v_occurred_at timestamptz;
  v_due_at timestamptz;
  v_completed_at timestamptz;
  v_source_updated_at timestamptz;
BEGIN
  PERFORM ingestion.assert_connector_domain_v2(p_connector_key,'activity');

  IF jsonb_typeof(p_source_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'SOURCE_PAYLOAD_MUST_BE_OBJECT';
  END IF;
  IF NULLIF(btrim(COALESCE(p_source_record_id,'')),'') IS NULL
     OR length(btrim(p_source_record_id))>200 THEN
    RAISE EXCEPTION 'SOURCE_RECORD_ID_INVALID';
  END IF;

  v_deal_source_record_id := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'deal_source_record_id');
  v_sales_rep := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'sales_rep');
  v_activity_type := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'activity_type');
  v_occurred_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'occurred_at'),'')::timestamptz;
  v_due_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'due_at'),'')::timestamptz;
  v_completed_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'completed_at'),'')::timestamptz;
  v_source_updated_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'source_updated_at'),'')::timestamptz;

  IF v_activity_type NOT IN ('task','email','call','meeting','other') THEN
    RAISE EXCEPTION 'ACTIVITY_TYPE_INVALID';
  END IF;

  INSERT INTO reporting.activities(
    connector_key,source_record_id,deal_source_record_id,sales_rep,
    activity_type,occurred_at,due_at,completed_at,source_updated_at,ingested_at
  )
  VALUES(
    p_connector_key,btrim(p_source_record_id),v_deal_source_record_id,
    v_sales_rep,v_activity_type,v_occurred_at,v_due_at,
    v_completed_at,v_source_updated_at,now()
  )
  ON CONFLICT(connector_key,source_record_id)
  DO UPDATE SET
    deal_source_record_id=EXCLUDED.deal_source_record_id,
    sales_rep=EXCLUDED.sales_rep,
    activity_type=EXCLUDED.activity_type,
    occurred_at=EXCLUDED.occurred_at,
    due_at=EXCLUDED.due_at,
    completed_at=EXCLUDED.completed_at,
    source_updated_at=EXCLUDED.source_updated_at,
    ingested_at=now();

  PERFORM ingestion.refresh_data_domain_status_v2('activities');
  RETURN jsonb_build_object(
    'status','upserted','domain','activities',
    'connector_key',p_connector_key,'source_record_id',btrim(p_source_record_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.ingest_subscription_event_from_source_v2(
  p_connector_key text,
  p_source_record_id text,
  p_source_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting,ingestion
AS $$
DECLARE
  v_account_key text;
  v_sales_rep text;
  v_segment text;
  v_region text;
  v_industry text;
  v_event_type text;
  v_mrr_delta numeric(18,2);
  v_currency_code text;
  v_business_currency text;
  v_occurred_at timestamptz;
  v_source_updated_at timestamptz;
BEGIN
  PERFORM ingestion.assert_connector_domain_v2(p_connector_key,'subscription');

  IF jsonb_typeof(p_source_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'SOURCE_PAYLOAD_MUST_BE_OBJECT';
  END IF;
  IF NULLIF(btrim(COALESCE(p_source_record_id,'')),'') IS NULL
     OR length(btrim(p_source_record_id))>200 THEN
    RAISE EXCEPTION 'SOURCE_RECORD_ID_INVALID';
  END IF;

  SELECT trim(both FROM currency_code::text)
  INTO v_business_currency
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;

  v_account_key := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'account_key');
  v_sales_rep := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'sales_rep');
  v_segment := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'segment');
  v_region := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'region');
  v_industry := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'industry');
  v_event_type := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'subscription_event_type');
  v_mrr_delta := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'mrr_delta'),'')::numeric(18,2);
  v_currency_code := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'currency_code');
  v_occurred_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'occurred_at'),'')::timestamptz;
  v_source_updated_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'source_updated_at'),'')::timestamptz;

  IF NULLIF(btrim(COALESCE(v_account_key,'')),'') IS NULL THEN
    RAISE EXCEPTION 'SUBSCRIPTION_ACCOUNT_KEY_REQUIRED';
  END IF;
  IF v_event_type NOT IN ('start','expansion','contraction','churn','renewal') THEN
    RAISE EXCEPTION 'SUBSCRIPTION_EVENT_TYPE_INVALID';
  END IF;
  IF v_mrr_delta IS NULL THEN
    RAISE EXCEPTION 'SUBSCRIPTION_MRR_DELTA_REQUIRED';
  END IF;
  IF (v_event_type IN ('start','expansion') AND v_mrr_delta<=0)
     OR (v_event_type IN ('contraction','churn') AND v_mrr_delta>=0)
     OR (v_event_type='renewal' AND v_mrr_delta<0) THEN
    RAISE EXCEPTION 'SUBSCRIPTION_MRR_DELTA_SIGN_INVALID';
  END IF;
  IF v_currency_code IS NULL OR v_currency_code !~ '^[A-Z]{3}$'
     OR v_business_currency IS NULL OR v_currency_code<>v_business_currency THEN
    RAISE EXCEPTION 'CURRENCY_NOT_SUPPORTED';
  END IF;
  IF v_occurred_at IS NULL THEN
    RAISE EXCEPTION 'SUBSCRIPTION_OCCURRED_AT_REQUIRED';
  END IF;

  INSERT INTO reporting.subscription_events(
    connector_key,source_record_id,account_key,sales_rep,segment,region,
    industry,event_type,mrr_delta,currency_code,occurred_at,
    source_updated_at,ingested_at
  )
  VALUES(
    p_connector_key,btrim(p_source_record_id),v_account_key,v_sales_rep,
    v_segment,v_region,v_industry,v_event_type,v_mrr_delta,
    v_currency_code,v_occurred_at,v_source_updated_at,now()
  )
  ON CONFLICT(connector_key,source_record_id)
  DO UPDATE SET
    account_key=EXCLUDED.account_key,
    sales_rep=EXCLUDED.sales_rep,
    segment=EXCLUDED.segment,
    region=EXCLUDED.region,
    industry=EXCLUDED.industry,
    event_type=EXCLUDED.event_type,
    mrr_delta=EXCLUDED.mrr_delta,
    currency_code=EXCLUDED.currency_code,
    occurred_at=EXCLUDED.occurred_at,
    source_updated_at=EXCLUDED.source_updated_at,
    ingested_at=now();

  PERFORM ingestion.refresh_data_domain_status_v2('subscriptions');
  RETURN jsonb_build_object(
    'status','upserted','domain','subscriptions',
    'connector_key',p_connector_key,'source_record_id',btrim(p_source_record_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.ingest_target_from_source_v2(
  p_connector_key text,
  p_source_record_id text,
  p_source_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting,ingestion
AS $$
DECLARE
  v_target_type text;
  v_sales_rep text;
  v_department_key text;
  v_period_start date;
  v_period_end date;
  v_target_amount numeric(18,2);
  v_currency_code text;
  v_business_currency text;
  v_source_updated_at timestamptz;
BEGIN
  PERFORM ingestion.assert_connector_domain_v2(p_connector_key,'target');

  IF jsonb_typeof(p_source_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'SOURCE_PAYLOAD_MUST_BE_OBJECT';
  END IF;
  IF NULLIF(btrim(COALESCE(p_source_record_id,'')),'') IS NULL
     OR length(btrim(p_source_record_id))>200 THEN
    RAISE EXCEPTION 'SOURCE_RECORD_ID_INVALID';
  END IF;

  SELECT trim(both FROM currency_code::text)
  INTO v_business_currency
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;

  v_target_type := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'target_type');
  v_sales_rep := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'sales_rep');
  v_department_key := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'department_key');
  v_period_start := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'period_start'),'')::timestamptz::date;
  v_period_end := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'period_end'),'')::timestamptz::date;
  v_target_amount := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'target_amount'),'')::numeric(18,2);
  v_currency_code := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'currency_code');
  v_source_updated_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'source_updated_at'),'')::timestamptz;

  IF v_target_type NOT IN ('revenue_quota','pipeline_target') THEN
    RAISE EXCEPTION 'TARGET_TYPE_INVALID';
  END IF;
  IF v_period_start IS NULL OR v_period_end IS NULL OR v_period_start>v_period_end THEN
    RAISE EXCEPTION 'TARGET_PERIOD_INVALID';
  END IF;
  IF v_target_amount IS NULL OR v_target_amount<0 THEN
    RAISE EXCEPTION 'TARGET_AMOUNT_INVALID';
  END IF;
  IF v_currency_code IS NULL OR v_currency_code !~ '^[A-Z]{3}$'
     OR v_business_currency IS NULL OR v_currency_code<>v_business_currency THEN
    RAISE EXCEPTION 'CURRENCY_NOT_SUPPORTED';
  END IF;

  INSERT INTO reporting.revenue_targets(
    connector_key,source_record_id,target_type,sales_rep,department_key,
    period_start,period_end,target_amount,currency_code,active,
    source_updated_at,ingested_at
  )
  VALUES(
    p_connector_key,btrim(p_source_record_id),v_target_type,v_sales_rep,
    v_department_key,v_period_start,v_period_end,v_target_amount,
    v_currency_code,true,v_source_updated_at,now()
  )
  ON CONFLICT(connector_key,source_record_id)
  DO UPDATE SET
    target_type=EXCLUDED.target_type,
    sales_rep=EXCLUDED.sales_rep,
    department_key=EXCLUDED.department_key,
    period_start=EXCLUDED.period_start,
    period_end=EXCLUDED.period_end,
    target_amount=EXCLUDED.target_amount,
    currency_code=EXCLUDED.currency_code,
    active=true,
    source_updated_at=EXCLUDED.source_updated_at,
    ingested_at=now();

  PERFORM ingestion.refresh_data_domain_status_v2('targets');
  RETURN jsonb_build_object(
    'status','upserted','domain','targets',
    'connector_key',p_connector_key,'source_record_id',btrim(p_source_record_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.ingest_forecast_snapshot_from_source_v2(
  p_connector_key text,
  p_source_record_id text,
  p_source_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting,ingestion
AS $$
DECLARE
  v_snapshot_at timestamptz;
  v_period_start date;
  v_period_end date;
  v_sales_rep text;
  v_forecast_category text;
  v_forecast_amount numeric(18,2);
  v_actual_amount numeric(18,2);
  v_currency_code text;
  v_business_currency text;
  v_source_updated_at timestamptz;
BEGIN
  PERFORM ingestion.assert_connector_domain_v2(p_connector_key,'forecast');

  IF jsonb_typeof(p_source_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'SOURCE_PAYLOAD_MUST_BE_OBJECT';
  END IF;
  IF NULLIF(btrim(COALESCE(p_source_record_id,'')),'') IS NULL
     OR length(btrim(p_source_record_id))>200 THEN
    RAISE EXCEPTION 'SOURCE_RECORD_ID_INVALID';
  END IF;

  SELECT trim(both FROM currency_code::text)
  INTO v_business_currency
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;

  v_snapshot_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'snapshot_at'),'')::timestamptz;
  v_period_start := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'period_start'),'')::timestamptz::date;
  v_period_end := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'period_end'),'')::timestamptz::date;
  v_sales_rep := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'sales_rep');
  v_forecast_category := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'forecast_category');
  v_forecast_amount := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'forecast_amount'),'')::numeric(18,2);
  v_actual_amount := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'actual_amount'),'')::numeric(18,2);
  v_currency_code := ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'currency_code');
  v_source_updated_at := NULLIF(ingestion.resolve_mapped_text(p_connector_key,p_source_payload,'source_updated_at'),'')::timestamptz;

  IF v_snapshot_at IS NULL THEN
    RAISE EXCEPTION 'FORECAST_SNAPSHOT_AT_REQUIRED';
  END IF;
  IF v_period_start IS NULL OR v_period_end IS NULL OR v_period_start>v_period_end THEN
    RAISE EXCEPTION 'FORECAST_PERIOD_INVALID';
  END IF;
  IF v_forecast_amount IS NULL OR v_forecast_amount<0
     OR (v_actual_amount IS NOT NULL AND v_actual_amount<0) THEN
    RAISE EXCEPTION 'FORECAST_AMOUNT_INVALID';
  END IF;
  IF v_forecast_category IS NOT NULL
     AND v_forecast_category NOT IN (
       'pipeline','best_case','commit','closed','omitted'
     ) THEN
    RAISE EXCEPTION 'FORECAST_CATEGORY_INVALID';
  END IF;
  IF v_currency_code IS NULL OR v_currency_code !~ '^[A-Z]{3}$'
     OR v_business_currency IS NULL OR v_currency_code<>v_business_currency THEN
    RAISE EXCEPTION 'CURRENCY_NOT_SUPPORTED';
  END IF;

  INSERT INTO reporting.forecast_snapshots(
    connector_key,source_record_id,snapshot_at,period_start,period_end,
    sales_rep,forecast_category,forecast_amount,actual_amount,
    currency_code,source_updated_at,ingested_at
  )
  VALUES(
    p_connector_key,btrim(p_source_record_id),v_snapshot_at,v_period_start,
    v_period_end,v_sales_rep,v_forecast_category,v_forecast_amount,
    v_actual_amount,v_currency_code,v_source_updated_at,now()
  )
  ON CONFLICT(connector_key,source_record_id)
  DO UPDATE SET
    snapshot_at=EXCLUDED.snapshot_at,
    period_start=EXCLUDED.period_start,
    period_end=EXCLUDED.period_end,
    sales_rep=EXCLUDED.sales_rep,
    forecast_category=EXCLUDED.forecast_category,
    forecast_amount=EXCLUDED.forecast_amount,
    actual_amount=EXCLUDED.actual_amount,
    currency_code=EXCLUDED.currency_code,
    source_updated_at=EXCLUDED.source_updated_at,
    ingested_at=now();

  PERFORM ingestion.refresh_data_domain_status_v2('forecasts');
  RETURN jsonb_build_object(
    'status','upserted','domain','forecasts',
    'connector_key',p_connector_key,'source_record_id',btrim(p_source_record_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.ingest_revenue_domain_record_v2(
  p_connector_key text,
  p_source_record_id text,
  p_source_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting,ingestion
AS $$
DECLARE
  v_object_type text;
  v_deal_id bigint;
  v_ingestion_status text;
  v_result jsonb;
BEGIN
  SELECT object_type
  INTO v_object_type
  FROM governance.connector_registry
  WHERE connector_key=p_connector_key
    AND contract_version=1
    AND active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONNECTOR_NOT_ACTIVE: %',p_connector_key;
  END IF;

  CASE v_object_type
    WHEN 'deal' THEN
      SELECT deal_id,ingestion_status
      INTO v_deal_id,v_ingestion_status
      FROM ingestion.ingest_deal_from_source(
        p_connector_key,p_source_record_id,p_source_payload
      );

      PERFORM ingestion.refresh_data_domain_status_v2('deals');
      v_result := jsonb_build_object(
        'status',v_ingestion_status,
        'domain','deals',
        'connector_key',p_connector_key,
        'source_record_id',btrim(p_source_record_id),
        'deal_id',v_deal_id
      );

    WHEN 'funnel' THEN
      v_result := ingestion.ingest_funnel_record_from_source_v2(
        p_connector_key,p_source_record_id,p_source_payload
      );

    WHEN 'activity' THEN
      v_result := ingestion.ingest_activity_from_source_v2(
        p_connector_key,p_source_record_id,p_source_payload
      );

    WHEN 'subscription' THEN
      v_result := ingestion.ingest_subscription_event_from_source_v2(
        p_connector_key,p_source_record_id,p_source_payload
      );

    WHEN 'target' THEN
      v_result := ingestion.ingest_target_from_source_v2(
        p_connector_key,p_source_record_id,p_source_payload
      );

    WHEN 'forecast' THEN
      v_result := ingestion.ingest_forecast_snapshot_from_source_v2(
        p_connector_key,p_source_record_id,p_source_payload
      );

    ELSE
      RAISE EXCEPTION 'CONNECTOR_OBJECT_TYPE_NOT_SUPPORTED: %',v_object_type;
  END CASE;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.ingest_revenue_domain_batch_v2(
  p_connector_key text,
  p_records jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog,governance,reporting,ingestion
AS $$
DECLARE
  v_count integer;
  v_processed integer := 0;
  v_record jsonb;
  v_source_record_id text;
  v_payload jsonb;
  v_object_type text;
BEGIN
  IF jsonb_typeof(p_records) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'SOURCE_RECORD_BATCH_MUST_BE_ARRAY';
  END IF;

  v_count := jsonb_array_length(p_records);
  IF v_count>10000 THEN
    RAISE EXCEPTION 'SOURCE_RECORD_BATCH_LIMIT_EXCEEDED';
  END IF;

  SELECT object_type
  INTO v_object_type
  FROM governance.connector_registry
  WHERE connector_key=p_connector_key
    AND contract_version=1
    AND active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONNECTOR_NOT_ACTIVE: %',p_connector_key;
  END IF;

  FOR v_record IN
    SELECT value FROM jsonb_array_elements(p_records)
  LOOP
    IF jsonb_typeof(v_record) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'SOURCE_RECORD_BATCH_ITEM_INVALID';
    END IF;

    v_source_record_id := btrim(COALESCE(v_record->>'source_record_id',''));
    v_payload := v_record->'source_payload';

    IF v_source_record_id=''
       OR length(v_source_record_id)>200 THEN
      RAISE EXCEPTION 'SOURCE_RECORD_ID_INVALID';
    END IF;
    IF jsonb_typeof(v_payload) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'SOURCE_PAYLOAD_MUST_BE_OBJECT';
    END IF;

    PERFORM ingestion.ingest_revenue_domain_record_v2(
      p_connector_key,v_source_record_id,v_payload
    );
    v_processed := v_processed+1;
  END LOOP;

  RETURN jsonb_build_object(
    'status','upserted',
    'connector_key',p_connector_key,
    'object_type',v_object_type,
    'processed_count',v_processed
  );
END;
$$;

REVOKE ALL ON FUNCTION ingestion.assert_connector_domain_v2(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.refresh_data_domain_status_v2(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_funnel_record_from_source_v2(text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_activity_from_source_v2(text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_subscription_event_from_source_v2(text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_target_from_source_v2(text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_forecast_snapshot_from_source_v2(text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_revenue_domain_record_v2(text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_revenue_domain_batch_v2(text,jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION ingestion.ingest_revenue_domain_record_v2(text,text,jsonb)
TO revint_connector_ingest;
GRANT EXECUTE ON FUNCTION ingestion.ingest_revenue_domain_batch_v2(text,jsonb)
TO revint_connector_ingest;

-- Existing deal-specific ingestion remains granted for backwards-compatible
-- Stage 3 / HubSpot paths. All new domains use the generic bounded gateways.

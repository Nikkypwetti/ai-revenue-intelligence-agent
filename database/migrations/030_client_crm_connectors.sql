\set ON_ERROR_STOP on

-- Reusable client CRM extensions for Agent V2.
-- Salesforce reuses the existing deal ingestion gateway.
-- Airtable lead intake uses the bounded funnel gateway below.

CREATE TABLE IF NOT EXISTS governance.connector_sync_state (
  connector_key text PRIMARY KEY
    REFERENCES governance.connector_registry(connector_key) ON DELETE CASCADE,
  watermark timestamptz,
  initial_lookback_days integer NOT NULL DEFAULT 30
    CHECK (initial_lookback_days BETWEEN 1 AND 3650),
  overlap_seconds integer NOT NULL DEFAULT 300
    CHECK (overlap_seconds BETWEEN 0 AND 3600),
  last_query_start_at timestamptz,
  last_query_end_at timestamptz,
  last_completed_at timestamptz,
  last_record_count integer NOT NULL DEFAULT 0 CHECK (last_record_count >= 0),
  last_rejected_count integer NOT NULL DEFAULT 0 CHECK (last_rejected_count >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON governance.connector_sync_state FROM PUBLIC;

CREATE OR REPLACE FUNCTION ingestion.ingest_funnel_from_source(
  p_connector_key text,
  p_source_record_id text,
  p_source_payload jsonb
)
RETURNS TABLE(funnel_id bigint, ingestion_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, governance, reporting, ingestion
AS $$
DECLARE
  v_connector governance.connector_registry%ROWTYPE;
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
  IF jsonb_typeof(p_source_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'SOURCE_PAYLOAD_MUST_BE_OBJECT';
  END IF;

  IF NULLIF(btrim(COALESCE(p_source_record_id, '')), '') IS NULL
     OR length(btrim(p_source_record_id)) > 200 THEN
    RAISE EXCEPTION 'SOURCE_RECORD_ID_INVALID';
  END IF;

  SELECT * INTO v_connector
  FROM governance.connector_registry
  WHERE connector_key = p_connector_key
    AND active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONNECTOR_NOT_ACTIVE: %', p_connector_key;
  END IF;

  IF v_connector.object_type <> 'funnel' OR v_connector.contract_version <> 1 THEN
    RAISE EXCEPTION 'CONNECTOR_CONTRACT_NOT_SUPPORTED: % v%',
      v_connector.object_type, v_connector.contract_version;
  END IF;

  v_sales_rep := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'sales_rep');
  v_lead_source := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'lead_source');
  v_campaign := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'campaign');
  v_segment := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'segment');
  v_region := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'region');
  v_industry := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'industry');
  v_created_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'created_at')::timestamptz;
  v_first_response_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'first_response_at')::timestamptz;
  v_mql_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'mql_at')::timestamptz;
  v_sql_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'sql_at')::timestamptz;
  v_opportunity_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'opportunity_at')::timestamptz;
  v_won_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'won_at')::timestamptz;
  v_lost_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'lost_at')::timestamptz;
  v_source_updated_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'source_updated_at')::timestamptz;

  IF v_created_at IS NULL THEN
    RAISE EXCEPTION 'FUNNEL_CREATED_AT_REQUIRED';
  END IF;

  IF v_won_at IS NOT NULL AND v_lost_at IS NOT NULL THEN
    RAISE EXCEPTION 'FUNNEL_WON_AND_LOST_MUTUALLY_EXCLUSIVE';
  END IF;

  IF (v_first_response_at IS NOT NULL AND v_first_response_at < v_created_at)
     OR (v_mql_at IS NOT NULL AND v_mql_at < v_created_at)
     OR (v_sql_at IS NOT NULL AND v_sql_at < v_created_at)
     OR (v_opportunity_at IS NOT NULL AND v_opportunity_at < v_created_at)
     OR (v_won_at IS NOT NULL AND v_won_at < v_created_at)
     OR (v_lost_at IS NOT NULL AND v_lost_at < v_created_at) THEN
    RAISE EXCEPTION 'FUNNEL_LIFECYCLE_TIMESTAMP_INVALID';
  END IF;

  RETURN QUERY
  INSERT INTO reporting.funnel_records (
    connector_key, source_record_id,
    sales_rep, lead_source, campaign, segment, region, industry,
    created_at, first_response_at, mql_at, sql_at, opportunity_at,
    won_at, lost_at, source_updated_at, ingested_at
  )
  VALUES (
    p_connector_key, btrim(p_source_record_id),
    v_sales_rep, v_lead_source, v_campaign, v_segment, v_region, v_industry,
    v_created_at, v_first_response_at, v_mql_at, v_sql_at, v_opportunity_at,
    v_won_at, v_lost_at, v_source_updated_at, now()
  )
  ON CONFLICT (connector_key, source_record_id)
  DO UPDATE SET
    sales_rep = EXCLUDED.sales_rep,
    lead_source = EXCLUDED.lead_source,
    campaign = EXCLUDED.campaign,
    segment = EXCLUDED.segment,
    region = EXCLUDED.region,
    industry = EXCLUDED.industry,
    created_at = EXCLUDED.created_at,
    first_response_at = EXCLUDED.first_response_at,
    mql_at = EXCLUDED.mql_at,
    sql_at = EXCLUDED.sql_at,
    opportunity_at = EXCLUDED.opportunity_at,
    won_at = EXCLUDED.won_at,
    lost_at = EXCLUDED.lost_at,
    source_updated_at = EXCLUDED.source_updated_at,
    ingested_at = now()
  RETURNING reporting.funnel_records.funnel_id, 'upserted'::text;
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.ingest_funnel_batch_from_source(
  p_connector_key text,
  p_records jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance, reporting, ingestion
AS $$
DECLARE
  v_count integer;
  v_processed integer := 0;
  v_record jsonb;
  v_record_id text;
  v_payload jsonb;
BEGIN
  IF jsonb_typeof(p_records) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'SOURCE_RECORD_BATCH_MUST_BE_ARRAY';
  END IF;

  v_count := jsonb_array_length(p_records);
  IF v_count > 10000 THEN
    RAISE EXCEPTION 'SOURCE_RECORD_BATCH_LIMIT_EXCEEDED';
  END IF;

  FOR v_record IN SELECT value FROM jsonb_array_elements(p_records)
  LOOP
    IF jsonb_typeof(v_record) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'SOURCE_RECORD_BATCH_ITEM_INVALID';
    END IF;

    v_record_id := btrim(COALESCE(v_record->>'source_record_id',''));
    v_payload := v_record->'source_payload';

    IF v_record_id = '' OR length(v_record_id) > 200 THEN
      RAISE EXCEPTION 'SOURCE_RECORD_ID_INVALID';
    END IF;

    PERFORM * FROM ingestion.ingest_funnel_from_source(
      p_connector_key, v_record_id, v_payload
    );
    v_processed := v_processed + 1;
  END LOOP;

  UPDATE governance.data_domain_status
  SET data_ready = true,
      record_count = (SELECT count(*) FROM reporting.funnel_records),
      last_loaded_at = now(),
      updated_at = now()
  WHERE domain_key = 'funnel';

  RETURN jsonb_build_object(
    'status','upserted',
    'connector_key',p_connector_key,
    'processed_count',v_processed
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.get_client_connector_sync_context(
  p_connector_key text,
  p_expected_type text,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
DECLARE
  v_connector governance.connector_registry%ROWTYPE;
  v_state governance.connector_sync_state%ROWTYPE;
  v_component_key text;
  v_gate jsonb;
  v_start timestamptz;
  v_currency text;
BEGIN
  IF p_expected_type NOT IN ('salesforce','airtable') THEN
    RAISE EXCEPTION 'CLIENT_CONNECTOR_TYPE_NOT_SUPPORTED: %', p_expected_type;
  END IF;

  SELECT * INTO v_connector
  FROM governance.connector_registry
  WHERE connector_key = p_connector_key
    AND connector_type = p_expected_type
    AND contract_version = 1
    AND active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLIENT_CONNECTOR_NOT_ACTIVE: %', p_connector_key;
  END IF;

  INSERT INTO governance.connector_sync_state(connector_key)
  VALUES (p_connector_key)
  ON CONFLICT (connector_key) DO NOTHING;

  SELECT * INTO v_state
  FROM governance.connector_sync_state
  WHERE connector_key = p_connector_key;

  SELECT trim(both FROM currency_code::text) INTO v_currency
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;

  IF v_currency IS NULL OR v_currency !~ '^[A-Z]{3}
  v_start := COALESCE(
    v_state.watermark - make_interval(secs => v_state.overlap_seconds),
    p_as_of - make_interval(days => v_state.initial_lookback_days)
  );

  RETURN jsonb_build_object(
    'connector_key', v_connector.connector_key,
    'connector_type', v_connector.connector_type,
    'object_type', v_connector.object_type,
    'contract_version', v_connector.contract_version,
    'currency_code', v_currency,
    'query_start_at', v_start,
    'query_end_at', p_as_of,
    'query_start_ms', floor(extract(epoch FROM v_start) * 1000)::bigint,
    'query_end_ms', floor(extract(epoch FROM p_as_of) * 1000)::bigint,
    'watermark', v_state.watermark,
    'initial_lookback_days', v_state.initial_lookback_days,
    'overlap_seconds', v_state.overlap_seconds,
    'reliability_component_key', v_component_key,
    'reliability_gate', v_gate
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.record_client_connector_sync_completion(
  p_event_id text,
  p_connector_key text,
  p_query_start_at timestamptz,
  p_query_end_at timestamptz,
  p_watermark timestamptz,
  p_source_count integer,
  p_record_count integer,
  p_rejected_count integer,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance, audit
AS $$
DECLARE
  v_connector governance.connector_registry%ROWTYPE;
  v_component_key text;
  v_result jsonb;
BEGIN
  SELECT * INTO v_connector
  FROM governance.connector_registry
  WHERE connector_key = p_connector_key
    AND connector_type IN ('salesforce','airtable')
    AND active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLIENT_CONNECTOR_NOT_ACTIVE: %', p_connector_key;
  END IF;

  IF p_query_start_at IS NULL OR p_query_end_at IS NULL
     OR p_query_start_at > p_query_end_at THEN
    RAISE EXCEPTION 'CONNECTOR_SYNC_WINDOW_INVALID';
  END IF;

  IF p_watermark IS NULL
     OR p_watermark < p_query_start_at
     OR p_watermark > p_query_end_at THEN
    RAISE EXCEPTION 'CONNECTOR_SYNC_WATERMARK_INVALID';
  END IF;

  IF p_source_count < 0 OR p_source_count > 10000
     OR p_record_count < 0 OR p_record_count > 10000
     OR p_rejected_count < 0 OR p_rejected_count > 10000
     OR p_record_count + p_rejected_count <> p_source_count THEN
    RAISE EXCEPTION 'CONNECTOR_SYNC_COUNTS_INVALID';
  END IF;

  v_component_key := CASE v_connector.connector_type
    WHEN 'salesforce' THEN 'salesforce_sync'
    WHEN 'airtable' THEN 'airtable_sync'
  END;

  INSERT INTO governance.connector_sync_state (
    connector_key, watermark,
    last_query_start_at, last_query_end_at, last_completed_at,
    last_record_count, last_rejected_count, updated_at
  )
  VALUES (
    p_connector_key, p_watermark,
    p_query_start_at, p_query_end_at, p_as_of,
    p_record_count, p_rejected_count, p_as_of
  )
  ON CONFLICT (connector_key) DO UPDATE SET
    watermark = GREATEST(
      COALESCE(governance.connector_sync_state.watermark, EXCLUDED.watermark),
      EXCLUDED.watermark
    ),
    last_query_start_at = EXCLUDED.last_query_start_at,
    last_query_end_at = EXCLUDED.last_query_end_at,
    last_completed_at = EXCLUDED.last_completed_at,
    last_record_count = EXCLUDED.last_record_count,
    last_rejected_count = EXCLUDED.last_rejected_count,
    updated_at = EXCLUDED.updated_at;

  v_result := governance.record_reliable_audit_event(
    p_event_id,
    NULL,
    NULL,
    'connector_sync_completed',
    v_connector.connector_type || '_connector',
    'n8n_client_connector',
    jsonb_build_object(
      'connector_key',p_connector_key,
      'connector_type',v_connector.connector_type,
      'object_type',v_connector.object_type,
      'query_start_at',p_query_start_at,
      'query_end_at',p_query_end_at,
      'watermark',p_watermark,
      'source_count',p_source_count,
      'record_count',p_record_count,
      'rejected_count',p_rejected_count,
      'status',CASE WHEN p_rejected_count > 0
        THEN 'completed_with_rejections'
        ELSE 'completed'
      END
    ),
    v_component_key,
    p_as_of
  );

  RETURN jsonb_build_object(
    'status','recorded',
    'connector_key',p_connector_key,
    'watermark',p_watermark,
    'record_count',p_record_count,
    'rejected_count',p_rejected_count,
    'audit',v_result
  );
END;
$$;

REVOKE ALL ON FUNCTION ingestion.ingest_funnel_from_source(text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_funnel_batch_from_source(text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.get_client_connector_sync_context(text,text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.record_client_connector_sync_completion(
  text,text,timestamptz,timestamptz,timestamptz,integer,integer,integer,timestamptz
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION ingestion.ingest_funnel_from_source(text,text,jsonb)
TO revint_connector_ingest;
GRANT EXECUTE ON FUNCTION ingestion.ingest_funnel_batch_from_source(text,jsonb)
TO revint_connector_ingest;
GRANT EXECUTE ON FUNCTION governance.get_client_connector_sync_context(text,text,timestamptz)
TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.record_client_connector_sync_completion(
  text,text,timestamptz,timestamptz,timestamptz,integer,integer,integer,timestamptz
) TO revint_audit_insert;
 THEN
    RAISE EXCEPTION 'BUSINESS_CURRENCY_NOT_CONFIGURED';
  END IF;

  v_component_key := CASE p_expected_type
    WHEN 'salesforce' THEN 'salesforce_sync'
    WHEN 'airtable' THEN 'airtable_sync'
  END;

  v_gate := governance.acquire_runtime_gate(v_component_key, p_as_of);
  v_start := COALESCE(
    v_state.watermark - make_interval(secs => v_state.overlap_seconds),
    p_as_of - make_interval(days => v_state.initial_lookback_days)
  );

  RETURN jsonb_build_object(
    'connector_key', v_connector.connector_key,
    'connector_type', v_connector.connector_type,
    'object_type', v_connector.object_type,
    'contract_version', v_connector.contract_version,
    'query_start_at', v_start,
    'query_end_at', p_as_of,
    'query_start_ms', floor(extract(epoch FROM v_start) * 1000)::bigint,
    'query_end_ms', floor(extract(epoch FROM p_as_of) * 1000)::bigint,
    'watermark', v_state.watermark,
    'initial_lookback_days', v_state.initial_lookback_days,
    'overlap_seconds', v_state.overlap_seconds,
    'reliability_component_key', v_component_key,
    'reliability_gate', v_gate
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.record_client_connector_sync_completion(
  p_event_id text,
  p_connector_key text,
  p_query_start_at timestamptz,
  p_query_end_at timestamptz,
  p_watermark timestamptz,
  p_source_count integer,
  p_record_count integer,
  p_rejected_count integer,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance, audit
AS $$
DECLARE
  v_connector governance.connector_registry%ROWTYPE;
  v_component_key text;
  v_result jsonb;
BEGIN
  SELECT * INTO v_connector
  FROM governance.connector_registry
  WHERE connector_key = p_connector_key
    AND connector_type IN ('salesforce','airtable')
    AND active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLIENT_CONNECTOR_NOT_ACTIVE: %', p_connector_key;
  END IF;

  IF p_query_start_at IS NULL OR p_query_end_at IS NULL
     OR p_query_start_at > p_query_end_at THEN
    RAISE EXCEPTION 'CONNECTOR_SYNC_WINDOW_INVALID';
  END IF;

  IF p_watermark IS NULL
     OR p_watermark < p_query_start_at
     OR p_watermark > p_query_end_at THEN
    RAISE EXCEPTION 'CONNECTOR_SYNC_WATERMARK_INVALID';
  END IF;

  IF p_source_count < 0 OR p_source_count > 10000
     OR p_record_count < 0 OR p_record_count > 10000
     OR p_rejected_count < 0 OR p_rejected_count > 10000
     OR p_record_count + p_rejected_count <> p_source_count THEN
    RAISE EXCEPTION 'CONNECTOR_SYNC_COUNTS_INVALID';
  END IF;

  v_component_key := CASE v_connector.connector_type
    WHEN 'salesforce' THEN 'salesforce_sync'
    WHEN 'airtable' THEN 'airtable_sync'
  END;

  INSERT INTO governance.connector_sync_state (
    connector_key, watermark,
    last_query_start_at, last_query_end_at, last_completed_at,
    last_record_count, last_rejected_count, updated_at
  )
  VALUES (
    p_connector_key, p_watermark,
    p_query_start_at, p_query_end_at, p_as_of,
    p_record_count, p_rejected_count, p_as_of
  )
  ON CONFLICT (connector_key) DO UPDATE SET
    watermark = GREATEST(
      COALESCE(governance.connector_sync_state.watermark, EXCLUDED.watermark),
      EXCLUDED.watermark
    ),
    last_query_start_at = EXCLUDED.last_query_start_at,
    last_query_end_at = EXCLUDED.last_query_end_at,
    last_completed_at = EXCLUDED.last_completed_at,
    last_record_count = EXCLUDED.last_record_count,
    last_rejected_count = EXCLUDED.last_rejected_count,
    updated_at = EXCLUDED.updated_at;

  v_result := governance.record_reliable_audit_event(
    p_event_id,
    NULL,
    NULL,
    'connector_sync_completed',
    v_connector.connector_type || '_connector',
    'n8n_client_connector',
    jsonb_build_object(
      'connector_key',p_connector_key,
      'connector_type',v_connector.connector_type,
      'object_type',v_connector.object_type,
      'query_start_at',p_query_start_at,
      'query_end_at',p_query_end_at,
      'watermark',p_watermark,
      'source_count',p_source_count,
      'record_count',p_record_count,
      'rejected_count',p_rejected_count,
      'status',CASE WHEN p_rejected_count > 0
        THEN 'completed_with_rejections'
        ELSE 'completed'
      END
    ),
    v_component_key,
    p_as_of
  );

  RETURN jsonb_build_object(
    'status','recorded',
    'connector_key',p_connector_key,
    'watermark',p_watermark,
    'record_count',p_record_count,
    'rejected_count',p_rejected_count,
    'audit',v_result
  );
END;
$$;

REVOKE ALL ON FUNCTION ingestion.ingest_funnel_from_source(text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_funnel_batch_from_source(text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.get_client_connector_sync_context(text,text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.record_client_connector_sync_completion(
  text,text,timestamptz,timestamptz,timestamptz,integer,integer,integer,timestamptz
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION ingestion.ingest_funnel_from_source(text,text,jsonb)
TO revint_connector_ingest;
GRANT EXECUTE ON FUNCTION ingestion.ingest_funnel_batch_from_source(text,jsonb)
TO revint_connector_ingest;
GRANT EXECUTE ON FUNCTION governance.get_client_connector_sync_context(text,text,timestamptz)
TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION governance.record_client_connector_sync_completion(
  text,text,timestamptz,timestamptz,timestamptz,integer,integer,integer,timestamptz
) TO revint_audit_insert;

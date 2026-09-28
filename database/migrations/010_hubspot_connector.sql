\set ON_ERROR_STOP on

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

CREATE OR REPLACE FUNCTION governance.get_connector_sync_context(
  p_connector_key text,
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
  v_currency text;
  v_gate jsonb;
  v_start timestamptz;
BEGIN
  SELECT * INTO v_connector
  FROM governance.connector_registry
  WHERE connector_key = p_connector_key
    AND connector_type = 'hubspot'
    AND object_type = 'deal'
    AND contract_version = 1
    AND active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'HUBSPOT_CONNECTOR_NOT_ACTIVE: %', p_connector_key;
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

  IF v_currency IS NULL OR v_currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'BUSINESS_CURRENCY_NOT_CONFIGURED';
  END IF;

  v_gate := governance.acquire_runtime_gate('hubspot_sync', p_as_of);
  v_start := COALESCE(
    v_state.watermark - make_interval(secs => v_state.overlap_seconds),
    p_as_of - make_interval(days => v_state.initial_lookback_days)
  );

  RETURN jsonb_build_object(
    'connector_key', v_connector.connector_key,
    'connector_type', v_connector.connector_type,
    'contract_version', v_connector.contract_version,
    'currency_code', v_currency,
    'query_start_at', v_start,
    'query_end_at', p_as_of,
    'query_start_ms', floor(extract(epoch FROM v_start) * 1000)::bigint,
    'query_end_ms', floor(extract(epoch FROM p_as_of) * 1000)::bigint,
    'watermark', v_state.watermark,
    'initial_lookback_days', v_state.initial_lookback_days,
    'overlap_seconds', v_state.overlap_seconds,
    'reliability_gate', v_gate
  );
END;
$$;

CREATE OR REPLACE FUNCTION ingestion.ingest_deal_batch_from_source(
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
    IF jsonb_typeof(v_payload) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'SOURCE_PAYLOAD_MUST_BE_OBJECT';
    END IF;

    PERFORM *
    FROM ingestion.ingest_deal_from_source(
      p_connector_key,
      v_record_id,
      v_payload
    );
    v_processed := v_processed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'status','upserted',
    'connector_key',p_connector_key,
    'processed_count',v_processed
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.record_connector_sync_completion(
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
  v_result jsonb;
BEGIN
  IF p_connector_key <> 'hubspot_primary' THEN
    RAISE EXCEPTION 'CONNECTOR_SYNC_COMPLETION_NOT_ALLOWED';
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

  IF NOT EXISTS (
    SELECT 1 FROM governance.connector_registry
    WHERE connector_key = p_connector_key
      AND connector_type = 'hubspot'
      AND active
  ) THEN
    RAISE EXCEPTION 'HUBSPOT_CONNECTOR_NOT_ACTIVE';
  END IF;

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
    'hubspot_connector',
    'n8n_hubspot_connector',
    jsonb_build_object(
      'connector_key',p_connector_key,
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
    'hubspot_sync',
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

REVOKE ALL ON FUNCTION governance.get_connector_sync_context(text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_deal_batch_from_source(text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.record_connector_sync_completion(
  text,text,timestamptz,timestamptz,timestamptz,integer,integer,integer,timestamptz
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION governance.get_connector_sync_context(text,timestamptz)
TO revint_governance_ro;

GRANT EXECUTE ON FUNCTION ingestion.ingest_deal_batch_from_source(text,jsonb)
TO revint_connector_ingest;

GRANT EXECUTE ON FUNCTION governance.record_connector_sync_completion(
  text,text,timestamptz,timestamptz,timestamptz,integer,integer,integer,timestamptz
) TO revint_audit_insert;

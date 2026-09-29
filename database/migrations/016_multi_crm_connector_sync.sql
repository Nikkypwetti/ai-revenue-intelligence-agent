\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION governance.connector_sync_component_key(
  p_connector_key text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT CASE
    WHEN p_connector_key ~ '^[a-z][a-z0-9_]{2,63}$'
      THEN regexp_replace(p_connector_key, '_primary$', '') || '_sync'
    ELSE NULL
  END;
$$;

REVOKE ALL ON FUNCTION governance.connector_sync_component_key(text) FROM PUBLIC;

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
  v_component_key text;
BEGIN
  SELECT * INTO v_connector
  FROM governance.connector_registry
  WHERE connector_key = p_connector_key
    AND connector_type IN ('hubspot','salesforce','airtable')
    AND object_type = 'deal'
    AND contract_version = 1
    AND active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CRM_CONNECTOR_NOT_ACTIVE: %', p_connector_key;
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

  v_component_key := governance.connector_sync_component_key(p_connector_key);
  IF v_component_key IS NULL THEN
    RAISE EXCEPTION 'CONNECTOR_COMPONENT_KEY_INVALID';
  END IF;

  v_gate := governance.acquire_runtime_gate(v_component_key, p_as_of);
  v_start := COALESCE(
    v_state.watermark - make_interval(secs => v_state.overlap_seconds),
    p_as_of - make_interval(days => v_state.initial_lookback_days)
  );

  RETURN jsonb_build_object(
    'connector_key', v_connector.connector_key,
    'connector_type', v_connector.connector_type,
    'contract_version', v_connector.contract_version,
    'currency_code', v_currency,
    'component_key', v_component_key,
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
  v_connector_type text;
  v_component_key text;
BEGIN
  SELECT connector_type INTO v_connector_type
  FROM governance.connector_registry
  WHERE connector_key = p_connector_key
    AND connector_type IN ('hubspot','salesforce','airtable')
    AND object_type = 'deal'
    AND contract_version = 1
    AND active;

  IF v_connector_type IS NULL THEN
    RAISE EXCEPTION 'CRM_CONNECTOR_NOT_ACTIVE: %', p_connector_key;
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

  v_component_key := governance.connector_sync_component_key(p_connector_key);

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
    updated_at = p_as_of;

  v_result := governance.record_reliable_audit_event(
    p_event_id,
    NULL,
    NULL,
    'connector_sync_completed',
    v_connector_type || '_connector',
    'n8n_' || v_connector_type || '_connector',
    jsonb_build_object(
      'connector_key',p_connector_key,
      'connector_type',v_connector_type,
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
    'connector_type',v_connector_type,
    'component_key',v_component_key,
    'watermark',p_watermark,
    'record_count',p_record_count,
    'rejected_count',p_rejected_count,
    'audit',v_result
  );
END;
$$;

REVOKE ALL ON FUNCTION governance.get_connector_sync_context(text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.record_connector_sync_completion(
  text,text,timestamptz,timestamptz,timestamptz,integer,integer,integer,timestamptz
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION governance.get_connector_sync_context(text,timestamptz)
TO revint_governance_ro;

GRANT EXECUTE ON FUNCTION governance.record_connector_sync_completion(
  text,text,timestamptz,timestamptz,timestamptz,integer,integer,integer,timestamptz
) TO revint_audit_insert;

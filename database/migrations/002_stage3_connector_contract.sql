\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS ingestion;
REVOKE ALL ON SCHEMA ingestion FROM PUBLIC;

CREATE TABLE IF NOT EXISTS governance.connector_registry (
  connector_key text PRIMARY KEY,
  connector_type text NOT NULL CHECK (
    connector_type IN ('hubspot','salesforce','postgresql','google_sheets','billing','rest_api')
  ),
  display_name text NOT NULL,
  object_type text NOT NULL DEFAULT 'deal' CHECK (object_type IN ('deal')),
  contract_version integer NOT NULL DEFAULT 1 CHECK (contract_version > 0),
  active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (connector_key ~ '^[a-z][a-z0-9_]{2,63}$')
);

CREATE TABLE IF NOT EXISTS governance.connector_field_mapping (
  connector_key text NOT NULL REFERENCES governance.connector_registry(connector_key) ON DELETE CASCADE,
  canonical_field text NOT NULL CHECK (
    canonical_field IN (
      'deal_name','amount','currency_code','stage_name','stage_category',
      'sales_rep','lead_source','created_at','expected_close_date',
      'closed_at','source_updated_at'
    )
  ),
  source_field text,
  transform_key text NOT NULL CHECK (
    transform_key IN ('text','numeric','uppercase','timestamp','value_map')
  ),
  required boolean NOT NULL DEFAULT false,
  default_value text,
  active boolean NOT NULL DEFAULT true,
  PRIMARY KEY (connector_key, canonical_field),
  CHECK (source_field IS NOT NULL OR default_value IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS governance.connector_value_mapping (
  connector_key text NOT NULL REFERENCES governance.connector_registry(connector_key) ON DELETE CASCADE,
  canonical_field text NOT NULL,
  source_value text NOT NULL,
  canonical_value text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  PRIMARY KEY (connector_key, canonical_field, source_value),
  CHECK (canonical_field IN ('stage_category')),
  CHECK (canonical_value IN ('open','won','lost'))
);

CREATE TABLE IF NOT EXISTS governance.query_templates (
  query_key text PRIMARY KEY,
  query_name text NOT NULL,
  description text NOT NULL,
  sql_template text NOT NULL,
  allowed_parameters text[] NOT NULL DEFAULT '{}',
  result_type text NOT NULL CHECK (
    result_type IN ('scalar','breakdown','trend','comparison','data_quality')
  ),
  maximum_rows integer NOT NULL DEFAULT 1 CHECK (maximum_rows BETWEEN 1 AND 10000),
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS reporting.deals (
  deal_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  connector_key text NOT NULL REFERENCES governance.connector_registry(connector_key),
  source_record_id text NOT NULL,
  deal_name text,
  amount numeric(18,2) NOT NULL CHECK (amount >= 0),
  currency_code char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
  stage_name text NOT NULL,
  stage_category text NOT NULL CHECK (stage_category IN ('open','won','lost')),
  sales_rep text,
  lead_source text,
  created_at timestamptz,
  expected_close_date timestamptz,
  closed_at timestamptz,
  source_updated_at timestamptz,
  source_payload_hash text NOT NULL,
  contract_version integer NOT NULL DEFAULT 1 CHECK (contract_version > 0),
  ingested_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (connector_key, source_record_id),
  CHECK (
    (stage_category = 'open' AND closed_at IS NULL)
    OR (stage_category IN ('won','lost') AND closed_at IS NOT NULL)
  )
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'revint_connector_ingest') THEN
    CREATE ROLE revint_connector_ingest NOLOGIN;
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION ingestion.resolve_mapped_text(
  p_connector_key text,
  p_source_payload jsonb,
  p_canonical_field text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, governance, ingestion
AS $$
DECLARE
  v_mapping governance.connector_field_mapping%ROWTYPE;
  v_raw text;
  v_mapped text;
BEGIN
  SELECT *
  INTO v_mapping
  FROM governance.connector_field_mapping
  WHERE connector_key = p_connector_key
    AND canonical_field = p_canonical_field
    AND active = true;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_mapping.source_field IS NOT NULL THEN
    v_raw := p_source_payload ->> v_mapping.source_field;
  END IF;

  IF NULLIF(btrim(COALESCE(v_raw, '')), '') IS NULL THEN
    v_raw := v_mapping.default_value;
  END IF;

  IF NULLIF(btrim(COALESCE(v_raw, '')), '') IS NULL THEN
    IF v_mapping.required THEN
      RAISE EXCEPTION 'REQUIRED_SOURCE_FIELD_MISSING: %', p_canonical_field;
    END IF;
    RETURN NULL;
  END IF;

  CASE v_mapping.transform_key
    WHEN 'text' THEN
      RETURN btrim(v_raw);

    WHEN 'uppercase' THEN
      RETURN upper(btrim(v_raw));

    WHEN 'numeric' THEN
      RETURN (btrim(v_raw)::numeric)::text;

    WHEN 'timestamp' THEN
      RETURN (btrim(v_raw)::timestamptz)::text;

    WHEN 'value_map' THEN
      SELECT canonical_value
      INTO v_mapped
      FROM governance.connector_value_mapping
      WHERE connector_key = p_connector_key
        AND canonical_field = p_canonical_field
        AND source_value = v_raw
        AND active = true;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'VALUE_MAPPING_NOT_FOUND: %=%', p_canonical_field, v_raw;
      END IF;

      RETURN v_mapped;

    ELSE
      RAISE EXCEPTION 'TRANSFORM_NOT_ALLOWED: %', v_mapping.transform_key;
  END CASE;
END;
$$;

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
BEGIN
  IF jsonb_typeof(p_source_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'SOURCE_PAYLOAD_MUST_BE_OBJECT';
  END IF;

  IF NULLIF(btrim(COALESCE(p_source_record_id, '')), '') IS NULL THEN
    RAISE EXCEPTION 'SOURCE_RECORD_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_connector
  FROM governance.connector_registry
  WHERE connector_key = p_connector_key
    AND active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONNECTOR_NOT_ACTIVE: %', p_connector_key;
  END IF;

  IF v_connector.object_type <> 'deal' OR v_connector.contract_version <> 1 THEN
    RAISE EXCEPTION 'CONNECTOR_CONTRACT_NOT_SUPPORTED: % v%', v_connector.object_type, v_connector.contract_version;
  END IF;

  SELECT currency_code::text
  INTO v_business_currency
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1;

  v_deal_name := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'deal_name');
  v_amount := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'amount')::numeric(18,2);
  v_currency_code := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'currency_code');
  v_stage_name := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'stage_name');
  v_stage_category := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'stage_category');
  v_sales_rep := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'sales_rep');
  v_lead_source := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'lead_source');
  v_created_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'created_at')::timestamptz;
  v_expected_close_date := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'expected_close_date')::timestamptz;
  v_closed_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'closed_at')::timestamptz;
  v_source_updated_at := ingestion.resolve_mapped_text(p_connector_key, p_source_payload, 'source_updated_at')::timestamptz;

  IF v_amount IS NULL THEN
    RAISE EXCEPTION 'CANONICAL_AMOUNT_REQUIRED';
  END IF;

  IF v_currency_code IS NULL OR v_currency_code !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'CANONICAL_CURRENCY_INVALID';
  END IF;

  IF v_business_currency IS NULL OR v_currency_code <> v_business_currency THEN
    RAISE EXCEPTION 'CURRENCY_NOT_SUPPORTED: source %, business %', v_currency_code, COALESCE(v_business_currency, 'missing');
  END IF;

  IF NULLIF(btrim(COALESCE(v_stage_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'CANONICAL_STAGE_NAME_REQUIRED';
  END IF;

  IF v_stage_category NOT IN ('open','won','lost') THEN
    RAISE EXCEPTION 'CANONICAL_STAGE_CATEGORY_INVALID';
  END IF;

  IF v_stage_category = 'open' THEN
    v_closed_at := NULL;
  END IF;

  IF v_stage_category IN ('won','lost') AND v_closed_at IS NULL THEN
    RAISE EXCEPTION 'CLOSED_DEAL_REQUIRES_CLOSED_AT';
  END IF;

  RETURN QUERY
  INSERT INTO reporting.deals (
    connector_key,
    source_record_id,
    deal_name,
    amount,
    currency_code,
    stage_name,
    stage_category,
    sales_rep,
    lead_source,
    created_at,
    expected_close_date,
    closed_at,
    source_updated_at,
    source_payload_hash,
    contract_version,
    ingested_at
  )
  VALUES (
    p_connector_key,
    btrim(p_source_record_id),
    v_deal_name,
    v_amount,
    v_currency_code,
    v_stage_name,
    v_stage_category,
    v_sales_rep,
    v_lead_source,
    v_created_at,
    v_expected_close_date,
    v_closed_at,
    v_source_updated_at,
    md5(p_source_payload::text),
    v_connector.contract_version,
    now()
  )
  ON CONFLICT (connector_key, source_record_id)
  DO UPDATE SET
    deal_name = EXCLUDED.deal_name,
    amount = EXCLUDED.amount,
    currency_code = EXCLUDED.currency_code,
    stage_name = EXCLUDED.stage_name,
    stage_category = EXCLUDED.stage_category,
    sales_rep = EXCLUDED.sales_rep,
    lead_source = EXCLUDED.lead_source,
    created_at = EXCLUDED.created_at,
    expected_close_date = EXCLUDED.expected_close_date,
    closed_at = EXCLUDED.closed_at,
    source_updated_at = EXCLUDED.source_updated_at,
    source_payload_hash = EXCLUDED.source_payload_hash,
    contract_version = EXCLUDED.contract_version,
    ingested_at = now()
  RETURNING reporting.deals.deal_id, 'upserted'::text;
END;
$$;

REVOKE ALL ON FUNCTION ingestion.resolve_mapped_text(text,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION ingestion.ingest_deal_from_source(text,text,jsonb) FROM PUBLIC;

GRANT SELECT ON governance.connector_registry,
                governance.connector_field_mapping,
                governance.connector_value_mapping,
                governance.query_templates
TO revint_governance_ro;

GRANT SELECT ON reporting.deals TO revint_reporting_ro;

GRANT USAGE ON SCHEMA ingestion TO revint_connector_ingest;
GRANT EXECUTE ON FUNCTION ingestion.ingest_deal_from_source(text,text,jsonb)
TO revint_connector_ingest;

SELECT format('CREATE ROLE %I LOGIN', :'connector_writer_user')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'connector_writer_user'
)
\gexec

SELECT format(
  'ALTER ROLE %I PASSWORD %L',
  :'connector_writer_user',
  :'connector_writer_password'
)
\gexec

SELECT format(
  'GRANT revint_connector_ingest TO %I',
  :'connector_writer_user'
)
\gexec

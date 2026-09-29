BEGIN;

CREATE TABLE IF NOT EXISTS governance.ai_adapter_config (
  config_id smallint PRIMARY KEY DEFAULT 1
    CHECK (config_id = 1),
  provider_key text NOT NULL DEFAULT 'groq'
    CHECK (provider_key IN ('groq')),
  intent_enabled boolean NOT NULL DEFAULT false,
  summary_enabled boolean NOT NULL DEFAULT false,
  intent_model text NOT NULL DEFAULT 'openai/gpt-oss-20b',
  summary_model text NOT NULL DEFAULT 'openai/gpt-oss-20b',
  intent_temperature numeric(3,2) NOT NULL DEFAULT 0
    CHECK (intent_temperature >= 0 AND intent_temperature <= 1),
  summary_temperature numeric(3,2) NOT NULL DEFAULT 0.1
    CHECK (summary_temperature >= 0 AND summary_temperature <= 1),
  max_question_chars integer NOT NULL DEFAULT 1000
    CHECK (max_question_chars BETWEEN 100 AND 10000),
  max_summary_input_chars integer NOT NULL DEFAULT 20000
    CHECK (max_summary_input_chars BETWEEN 1000 AND 100000),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO governance.ai_adapter_config(config_id)
VALUES (1)
ON CONFLICT (config_id) DO NOTHING;

CREATE OR REPLACE FUNCTION governance.get_ai_adapter_policy()
RETURNS TABLE (
  provider_key text,
  intent_enabled boolean,
  summary_enabled boolean,
  intent_model text,
  summary_model text,
  intent_temperature numeric,
  summary_temperature numeric,
  max_question_chars integer,
  max_summary_input_chars integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
  SELECT
    c.provider_key,
    c.intent_enabled,
    c.summary_enabled,
    c.intent_model,
    c.summary_model,
    c.intent_temperature,
    c.summary_temperature,
    c.max_question_chars,
    c.max_summary_input_chars
  FROM governance.ai_adapter_config c
  WHERE c.config_id = 1;
$$;

REVOKE ALL ON governance.ai_adapter_config FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.get_ai_adapter_policy() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION governance.get_ai_adapter_policy()
TO revint_governance_ro;

COMMENT ON TABLE governance.ai_adapter_config IS
'Reusable provider-neutral policy for optional AI intent and management-summary adapters. Secrets are never stored here.';

COMMENT ON FUNCTION governance.get_ai_adapter_policy() IS
'Returns bounded AI adapter configuration to the least-privilege reporting runtime without exposing the backing table.';

COMMIT;

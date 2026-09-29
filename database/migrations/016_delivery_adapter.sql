BEGIN;

CREATE TABLE IF NOT EXISTS governance.delivery_adapter_config (
  config_id smallint PRIMARY KEY DEFAULT 1
    CHECK (config_id = 1),
  tenant_key text NOT NULL
    REFERENCES governance.tenant_registry(tenant_key),
  slack_report_enabled boolean NOT NULL DEFAULT false,
  max_slack_message_chars integer NOT NULL DEFAULT 12000
    CHECK (max_slack_message_chars BETWEEN 1000 AND 30000),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO governance.delivery_adapter_config(config_id,tenant_key)
SELECT 1, tenant_key
FROM governance.deployment_security_config
WHERE config_id=1
ON CONFLICT (config_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS governance.delivery_destination_registry (
  destination_key text PRIMARY KEY,
  tenant_key text NOT NULL
    REFERENCES governance.tenant_registry(tenant_key),
  provider_key text NOT NULL
    CHECK (provider_key IN ('slack')),
  purpose_key text NOT NULL
    CHECK (purpose_key IN ('manager_report','incident')),
  external_destination_id text NOT NULL,
  display_name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (destination_key ~ '^[a-z0-9][a-z0-9_-]{0,63}$'),
  CHECK (length(external_destination_id) BETWEEN 1 AND 200)
);

CREATE UNIQUE INDEX IF NOT EXISTS delivery_destination_one_active_uidx
ON governance.delivery_destination_registry(tenant_key,provider_key,purpose_key)
WHERE active;

CREATE TABLE IF NOT EXISTS governance.delivery_role_policy (
  role_key text NOT NULL
    REFERENCES governance.role_policy(role_key)
    ON DELETE CASCADE,
  delivery_key text NOT NULL
    CHECK (delivery_key IN ('slack_report')),
  allowed boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (role_key,delivery_key)
);

INSERT INTO governance.delivery_role_policy(role_key,delivery_key,allowed)
VALUES
  ('revenue_admin','slack_report',true),
  ('revenue_manager','slack_report',true),
  ('sales_rep','slack_report',false)
ON CONFLICT (role_key,delivery_key) DO UPDATE SET
  allowed=EXCLUDED.allowed,
  updated_at=now();

CREATE OR REPLACE FUNCTION governance.resolve_delivery_request(
  p_principal_key text,
  p_delivery_key text
)
RETURNS TABLE (
  allowed boolean,
  reason text,
  tenant_key text,
  provider_key text,
  destination_key text,
  external_destination_id text,
  display_name text,
  max_message_chars integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
DECLARE
  v_tenant text;
  v_enabled boolean := false;
  v_max integer := 12000;
BEGIN
  IF p_delivery_key <> 'slack_report' THEN
    RETURN QUERY SELECT false,'DELIVERY_KEY_NOT_SUPPORTED',NULL::text,NULL::text,
      NULL::text,NULL::text,NULL::text,NULL::integer;
    RETURN;
  END IF;

  SELECT c.tenant_key,c.slack_report_enabled,c.max_slack_message_chars
  INTO v_tenant,v_enabled,v_max
  FROM governance.delivery_adapter_config c
  JOIN governance.deployment_security_config d
    ON d.config_id=1 AND d.tenant_key=c.tenant_key
  JOIN governance.tenant_registry t
    ON t.tenant_key=c.tenant_key AND t.active
  WHERE c.config_id=1
    AND d.deployment_mode='isolated';

  IF v_tenant IS NULL THEN
    RETURN QUERY SELECT false,'DELIVERY_TENANT_NOT_CONFIGURED',NULL::text,NULL::text,
      NULL::text,NULL::text,NULL::text,NULL::integer;
    RETURN;
  END IF;

  IF NOT v_enabled THEN
    RETURN QUERY SELECT false,'DELIVERY_DISABLED',v_tenant,'slack',
      NULL::text,NULL::text,NULL::text,v_max;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM governance.principal_registry p
    WHERE p.principal_key=p_principal_key
      AND p.tenant_key=v_tenant
      AND p.active
  ) THEN
    RETURN QUERY SELECT false,'DELIVERY_PRINCIPAL_NOT_ALLOWED',v_tenant,'slack',
      NULL::text,NULL::text,NULL::text,v_max;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM governance.role_assignment ra
    JOIN governance.delivery_role_policy rp
      ON rp.role_key=ra.role_key
     AND rp.delivery_key=p_delivery_key
     AND rp.allowed
    JOIN governance.role_policy r
      ON r.role_key=ra.role_key
     AND r.active
    WHERE ra.principal_key=p_principal_key
      AND ra.active
  ) THEN
    RETURN QUERY SELECT false,'DELIVERY_ROLE_NOT_ALLOWED',v_tenant,'slack',
      NULL::text,NULL::text,NULL::text,v_max;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT true,'AUTHORIZED',v_tenant,d.provider_key,d.destination_key,
         d.external_destination_id,d.display_name,v_max
  FROM governance.delivery_destination_registry d
  WHERE d.tenant_key=v_tenant
    AND d.provider_key='slack'
    AND d.purpose_key='manager_report'
    AND d.active
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false,'TRUSTED_DESTINATION_NOT_CONFIGURED',v_tenant,'slack',
      NULL::text,NULL::text,NULL::text,v_max;
  END IF;
END;
$$;

REVOKE ALL ON governance.delivery_adapter_config FROM PUBLIC;
REVOKE ALL ON governance.delivery_destination_registry FROM PUBLIC;
REVOKE ALL ON governance.delivery_role_policy FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.resolve_delivery_request(text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION governance.resolve_delivery_request(text,text)
TO revint_governance_ro;

COMMENT ON TABLE governance.delivery_destination_registry IS
'Tenant-scoped trusted external destinations. Caller payloads and AI output cannot supply these destination IDs.';

COMMENT ON FUNCTION governance.resolve_delivery_request(text,text) IS
'Authorizes tenant-scoped manager delivery by principal role and resolves the trusted external destination.';

COMMIT;

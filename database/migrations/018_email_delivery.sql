BEGIN;

CREATE TABLE IF NOT EXISTS governance.email_delivery_config (
  config_id smallint PRIMARY KEY DEFAULT 1 CHECK (config_id=1),
  tenant_key text NOT NULL REFERENCES governance.tenant_registry(tenant_key),
  email_report_enabled boolean NOT NULL DEFAULT false,
  max_subject_chars integer NOT NULL DEFAULT 180 CHECK (max_subject_chars BETWEEN 40 AND 300),
  max_body_chars integer NOT NULL DEFAULT 20000 CHECK (max_body_chars BETWEEN 1000 AND 50000),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO governance.email_delivery_config(config_id,tenant_key)
SELECT 1,tenant_key
FROM governance.deployment_security_config
WHERE config_id=1
ON CONFLICT (config_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS governance.email_destination_registry (
  destination_key text PRIMARY KEY,
  tenant_key text NOT NULL REFERENCES governance.tenant_registry(tenant_key),
  purpose_key text NOT NULL DEFAULT 'manager_report' CHECK (purpose_key='manager_report'),
  recipient_email text NOT NULL,
  display_name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (destination_key ~ '^[a-z0-9][a-z0-9_-]{0,63}$'),
  CHECK (recipient_email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'),
  CHECK (length(recipient_email) BETWEEN 3 AND 254)
);

CREATE UNIQUE INDEX IF NOT EXISTS email_destination_one_active_uidx
ON governance.email_destination_registry(tenant_key,purpose_key)
WHERE active;

CREATE TABLE IF NOT EXISTS governance.email_delivery_role_policy (
  role_key text PRIMARY KEY REFERENCES governance.role_policy(role_key) ON DELETE CASCADE,
  allowed boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO governance.email_delivery_role_policy(role_key,allowed)
VALUES
 ('revenue_admin',true),
 ('revenue_manager',true),
 ('sales_rep',false)
ON CONFLICT (role_key) DO UPDATE SET
 allowed=EXCLUDED.allowed,
 updated_at=now();

CREATE OR REPLACE FUNCTION governance.resolve_email_delivery_request(
  p_principal_key text
)
RETURNS TABLE (
  allowed boolean,
  reason text,
  tenant_key text,
  destination_key text,
  recipient_email text,
  display_name text,
  max_subject_chars integer,
  max_body_chars integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,governance
AS $$
DECLARE
  v_tenant text;
  v_enabled boolean := false;
  v_subject integer := 180;
  v_body integer := 20000;
BEGIN
  SELECT c.tenant_key,c.email_report_enabled,c.max_subject_chars,c.max_body_chars
  INTO v_tenant,v_enabled,v_subject,v_body
  FROM governance.email_delivery_config c
  JOIN governance.deployment_security_config d
    ON d.config_id=1 AND d.tenant_key=c.tenant_key
  JOIN governance.tenant_registry t
    ON t.tenant_key=c.tenant_key AND t.active
  WHERE c.config_id=1 AND d.deployment_mode='isolated';

  IF v_tenant IS NULL THEN
    RETURN QUERY SELECT false,'EMAIL_TENANT_NOT_CONFIGURED',NULL::text,NULL::text,NULL::text,NULL::text,NULL::integer,NULL::integer;
    RETURN;
  END IF;

  IF NOT v_enabled THEN
    RETURN QUERY SELECT false,'EMAIL_DELIVERY_DISABLED',v_tenant,NULL::text,NULL::text,NULL::text,v_subject,v_body;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM governance.principal_registry p
    WHERE p.principal_key=p_principal_key
      AND p.tenant_key=v_tenant
      AND p.active
  ) THEN
    RETURN QUERY SELECT false,'EMAIL_PRINCIPAL_NOT_ALLOWED',v_tenant,NULL::text,NULL::text,NULL::text,v_subject,v_body;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM governance.role_assignment ra
    JOIN governance.email_delivery_role_policy rp
      ON rp.role_key=ra.role_key AND rp.allowed
    JOIN governance.role_policy r
      ON r.role_key=ra.role_key AND r.active
    WHERE ra.principal_key=p_principal_key
      AND ra.active
  ) THEN
    RETURN QUERY SELECT false,'EMAIL_ROLE_NOT_ALLOWED',v_tenant,NULL::text,NULL::text,NULL::text,v_subject,v_body;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT true,'AUTHORIZED',v_tenant,d.destination_key,d.recipient_email,d.display_name,v_subject,v_body
  FROM governance.email_destination_registry d
  WHERE d.tenant_key=v_tenant
    AND d.purpose_key='manager_report'
    AND d.active
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false,'EMAIL_TRUSTED_DESTINATION_NOT_CONFIGURED',v_tenant,NULL::text,NULL::text,NULL::text,v_subject,v_body;
  END IF;
END;
$$;

REVOKE ALL ON governance.email_delivery_config FROM PUBLIC;
REVOKE ALL ON governance.email_destination_registry FROM PUBLIC;
REVOKE ALL ON governance.email_delivery_role_policy FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.resolve_email_delivery_request(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION governance.resolve_email_delivery_request(text)
TO revint_governance_ro;

COMMENT ON FUNCTION governance.resolve_email_delivery_request(text) IS
'Authorizes manager email delivery by tenant/principal role and resolves one trusted server-side recipient.';

COMMIT;

\set ON_ERROR_STOP on

BEGIN;

CREATE TABLE IF NOT EXISTS governance.tenant_registry (
  tenant_key text PRIMARY KEY,
  display_name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (tenant_key ~ '^[a-z0-9][a-z0-9_-]{0,63}$')
);

INSERT INTO governance.tenant_registry(tenant_key,display_name,active)
VALUES ('default','Default isolated deployment',true)
ON CONFLICT (tenant_key) DO NOTHING;

ALTER TABLE governance.principal_registry
  ADD COLUMN IF NOT EXISTS tenant_key text;

UPDATE governance.principal_registry
SET tenant_key='default'
WHERE tenant_key IS NULL;

ALTER TABLE governance.principal_registry
  ALTER COLUMN tenant_key SET DEFAULT 'default';
ALTER TABLE governance.principal_registry
  ALTER COLUMN tenant_key SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='principal_registry_tenant_fk'
      AND conrelid='governance.principal_registry'::regclass
  ) THEN
    ALTER TABLE governance.principal_registry
      ADD CONSTRAINT principal_registry_tenant_fk
      FOREIGN KEY (tenant_key)
      REFERENCES governance.tenant_registry(tenant_key);
  END IF;
END
$$;

DROP INDEX IF EXISTS governance.principal_registry_provider_subject_uidx;

CREATE UNIQUE INDEX IF NOT EXISTS
  principal_registry_tenant_provider_subject_uidx
ON governance.principal_registry(
  tenant_key,identity_provider,external_subject
)
WHERE external_subject IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS
  principal_registry_tenant_principal_uidx
ON governance.principal_registry(tenant_key,principal_key);
CREATE TABLE IF NOT EXISTS governance.deployment_security_config (
  config_id smallint PRIMARY KEY DEFAULT 1 CHECK (config_id=1),
  tenant_key text NOT NULL
    REFERENCES governance.tenant_registry(tenant_key),
  deployment_mode text NOT NULL DEFAULT 'isolated'
    CHECK (deployment_mode='isolated'),
  human_auth_mode text NOT NULL DEFAULT 'oidc'
    CHECK (human_auth_mode IN ('oidc','disabled')),
  machine_auth_mode text NOT NULL DEFAULT 'service_credential'
    CHECK (machine_auth_mode='service_credential'),
  report_service_enabled boolean NOT NULL DEFAULT true,
  ingest_service_enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO governance.deployment_security_config(
  config_id,tenant_key,deployment_mode,human_auth_mode,
  machine_auth_mode,report_service_enabled,ingest_service_enabled
)
VALUES (
  1,'default','isolated','oidc','service_credential',true,true
)
ON CONFLICT (config_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS governance.service_identity_registry (
  service_key text PRIMARY KEY,
  tenant_key text NOT NULL,
  principal_key text NOT NULL,
  display_name text NOT NULL,
  allowed_routes text[] NOT NULL DEFAULT '{}',
  requests_per_minute integer NOT NULL DEFAULT 60
    CHECK (requests_per_minute BETWEEN 1 AND 10000),
  max_body_bytes integer NOT NULL DEFAULT 65536
    CHECK (max_body_bytes BETWEEN 1024 AND 1048576),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (service_key ~ '^[a-z0-9][a-z0-9_-]{0,63}$'),
  CHECK (cardinality(allowed_routes) BETWEEN 1 AND 16),
  CHECK (
    allowed_routes <@ ARRAY[
      'report_api','deal_ingest','revenue_domain_ingest'
    ]::text[]
  ),
  CONSTRAINT service_identity_tenant_principal_fk
    FOREIGN KEY (tenant_key,principal_key)
    REFERENCES governance.principal_registry(tenant_key,principal_key)
    ON UPDATE CASCADE
    ON DELETE CASCADE
);

CREATE OR REPLACE FUNCTION governance.validate_service_identity_routes()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog,governance
AS $$
DECLARE
  v_routes text[];
BEGIN
  SELECT COALESCE(array_agg(DISTINCT r ORDER BY r),'{}'::text[])
  INTO v_routes
  FROM unnest(COALESCE(NEW.allowed_routes,'{}'::text[])) r;

  NEW.allowed_routes := v_routes;
  NEW.updated_at := now();

  IF NEW.active AND EXISTS (
    SELECT 1
    FROM governance.service_identity_registry s
    WHERE s.tenant_key=NEW.tenant_key
      AND s.service_key<>NEW.service_key
      AND s.active
      AND s.allowed_routes && NEW.allowed_routes
  ) THEN
    RAISE EXCEPTION 'SERVICE_ROUTE_ALREADY_BOUND';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_service_identity_routes
ON governance.service_identity_registry;

CREATE TRIGGER trg_validate_service_identity_routes
BEFORE INSERT OR UPDATE OF tenant_key,allowed_routes,active
ON governance.service_identity_registry
FOR EACH ROW
EXECUTE FUNCTION governance.validate_service_identity_routes();

CREATE OR REPLACE FUNCTION governance.resolve_active_service_identity(
  p_route_key text
)
RETURNS TABLE (
  mapped boolean,
  tenant_key text,
  service_key text,
  principal_key text,
  requests_per_minute integer,
  max_body_bytes integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance
AS $$
DECLARE
  v_tenant text;
  v_enabled boolean;
BEGIN
  IF p_route_key NOT IN (
    'report_api','deal_ingest','revenue_domain_ingest'
  ) THEN
    RETURN QUERY
    SELECT false,NULL::text,NULL::text,NULL::text,
           NULL::integer,NULL::integer;
    RETURN;
  END IF;

  SELECT c.tenant_key,
         CASE
           WHEN p_route_key='report_api'
             THEN c.report_service_enabled
           ELSE c.ingest_service_enabled
         END
  INTO v_tenant,v_enabled
  FROM governance.deployment_security_config c
  JOIN governance.tenant_registry t
    ON t.tenant_key=c.tenant_key
   AND t.active
  WHERE c.config_id=1
    AND c.deployment_mode='isolated';

  IF NOT FOUND OR NOT COALESCE(v_enabled,false) THEN
    RETURN QUERY
    SELECT false,v_tenant,NULL::text,NULL::text,
           NULL::integer,NULL::integer;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT true,s.tenant_key,s.service_key,s.principal_key,
         s.requests_per_minute,s.max_body_bytes
  FROM governance.service_identity_registry s
  JOIN governance.principal_registry p
    ON p.tenant_key=s.tenant_key
   AND p.principal_key=s.principal_key
   AND p.active
  WHERE s.tenant_key=v_tenant
    AND s.active
    AND p_route_key=ANY(s.allowed_routes)
  ORDER BY s.service_key
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY
    SELECT false,v_tenant,NULL::text,NULL::text,
           NULL::integer,NULL::integer;
  END IF;
END;
$$;
CREATE OR REPLACE FUNCTION governance.resolve_external_principal(
  p_identity_provider text,
  p_external_subject text
)
RETURNS TABLE (
  mapped boolean,
  principal_key text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog,governance
AS $$
  WITH deployment AS (
    SELECT c.tenant_key
    FROM governance.deployment_security_config c
    JOIN governance.tenant_registry t
      ON t.tenant_key=c.tenant_key
     AND t.active
    WHERE c.config_id=1
      AND c.deployment_mode='isolated'
  )
  SELECT
    (p.principal_key IS NOT NULL) AS mapped,
    p.principal_key
  FROM deployment d
  LEFT JOIN LATERAL (
    SELECT pr.principal_key
    FROM governance.principal_registry pr
    WHERE pr.tenant_key=d.tenant_key
      AND pr.identity_provider=
          NULLIF(btrim(p_identity_provider),'')
      AND pr.external_subject=
          NULLIF(btrim(p_external_subject),'')
      AND pr.active
    LIMIT 1
  ) p ON true
  WHERE char_length(COALESCE(p_identity_provider,'')) <= 64
    AND char_length(COALESCE(p_external_subject,'')) <= 512;
$$;

REVOKE ALL ON governance.tenant_registry FROM PUBLIC;
REVOKE ALL ON governance.deployment_security_config FROM PUBLIC;
REVOKE ALL ON governance.service_identity_registry FROM PUBLIC;

REVOKE ALL ON FUNCTION
  governance.resolve_active_service_identity(text)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
  governance.resolve_external_principal(text,text)
FROM PUBLIC;

GRANT SELECT ON governance.tenant_registry
TO revint_governance_ro;
GRANT EXECUTE ON FUNCTION
  governance.resolve_active_service_identity(text)
TO revint_governance_ro;

GRANT EXECUTE ON FUNCTION
  governance.resolve_external_principal(text,text)
TO revint_governance_ro;

COMMIT;

\set ON_ERROR_STOP on

BEGIN;

INSERT INTO governance.principal_registry(
  principal_key,display_name,identity_provider,external_subject,
  canonical_sales_rep,active,tenant_key
)
SELECT
  'service:report-api',
  'Agent V2 Report API Service',
  'service',
  NULL,
  NULL,
  true,
  c.tenant_key
FROM governance.deployment_security_config c
WHERE c.config_id=1
ON CONFLICT (principal_key) DO UPDATE SET
  display_name=EXCLUDED.display_name,
  identity_provider='service',
  external_subject=NULL,
  canonical_sales_rep=NULL,
  active=true,
  tenant_key=EXCLUDED.tenant_key,
  updated_at=now();
INSERT INTO governance.role_assignment(
  principal_key,role_key,active
)
VALUES ('service:report-api','revenue_admin',true)
ON CONFLICT (principal_key,role_key) DO UPDATE SET
  active=true;

INSERT INTO governance.service_identity_registry(
  service_key,tenant_key,principal_key,display_name,
  allowed_routes,requests_per_minute,max_body_bytes,active
)
SELECT
  'report_api',
  c.tenant_key,
  'service:report-api',
  'Agent V2 Report API',
  ARRAY['report_api']::text[],
  60,
  65536,
  true
FROM governance.deployment_security_config c
WHERE c.config_id=1
ON CONFLICT (service_key) DO UPDATE SET
  tenant_key=EXCLUDED.tenant_key,
  principal_key=EXCLUDED.principal_key,
  display_name=EXCLUDED.display_name,
  allowed_routes=EXCLUDED.allowed_routes,
  requests_per_minute=EXCLUDED.requests_per_minute,
  max_body_bytes=EXCLUDED.max_body_bytes,
  active=true,
  updated_at=now();

COMMIT;

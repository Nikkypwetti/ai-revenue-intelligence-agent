# Agent V2 — Reusable Security Gateway

## Purpose

The security gateway protects Agent V2 itself, independent of which CRM or data-source adapters are connected.

The default production model is **one isolated Agent V2 deployment per client**. Multi-tenant data sharing is intentionally not enabled by this implementation.

Core rule:

> Authenticate first. Bind identity server-side. Authorize deterministically. Execute with least privilege. Audit the result.

## Human versus machine access

Human users should use OIDC/SSO. Their external identity-provider subject resolves to a tenant-scoped Agent principal.

Machine-to-machine integrations use a service credential. The caller is authenticated by the route credential, then the Agent resolves the configured service principal from governance. Caller JSON cannot choose or elevate principal_key.

The n8n editor/backend remains bound to localhost in the reference deployment. Public access goes through the HTTPS ingress only.
## Tenant boundary

governance.tenant_registry stores reusable client/deployment identities.

governance.deployment_security_config has exactly one active deployment tenant and enforces deployment_mode=isolated.

Every governed principal has a tenant_key.

OIDC resolution is tenant-scoped. The same external subject in a different tenant does not resolve unless that tenant is the active deployment tenant.

Machine service identities are also tenant-scoped and must reference a principal from the same tenant.

## Service identity binding

The authenticated report route now executes:

1. INT | Authenticated Report Request
2. DB | Resolve Report Service
3. CTX | Bind Report Service
4. CTX | Interpret Report Request
5. deterministic authorization/execution

CTX | Bind Report Service overwrites any caller-supplied principal_key with the configured service principal.

The default report service principal is service:report-api. It is seeded with the existing revenue_admin reporting role for system-to-system analytics and can be reassigned to a narrower role for a client.
## Resource and abuse controls

Public ingress adds independent controls for report, SSO-report, and ingestion routes:

- per-IP request-rate limits
- bounded burst limits
- per-IP concurrent connection limit
- report request body limit
- ingestion request body limit
- POST-only webhook routes
- stripped client-supplied Authorization headers on machine webhook routes
- stripped client-supplied internal SSO identity headers on machine webhook routes
- TLS-only public deployment path
- hidden n8n backend/editor

Default reference limits:

| Control | Default |
|---|---:|
| Report rate | 60 requests/minute/IP |
| Report burst | 20 |
| Ingestion rate | 120 requests/minute/IP |
| Ingestion burst | 40 |
| SSO report rate | 60 requests/minute/IP |
| Report body | 64 KiB |
| Ingestion body | 128 KiB |
| Concurrent requests/IP | 20 |

These values are client/environment configuration, not hard-coded business logic.
## Fail-closed behavior

The request is rejected or becomes unauthorized when:

- the route credential is missing or invalid
- no active service identity exists for the report route
- the service principal is inactive
- the SSO subject is not mapped in the active tenant
- the request exceeds body/resource limits
- the principal has no active role
- the KPI/dimension/filter is not permitted
- the requested data scope is not available
- required Revenue Question Pack data domains are not ready

The LLM/intent interpreter does not make any of these authorization decisions.

## Client configuration

Initialize with scripts/init-security-gateway.sh.

Configure the client tenant with scripts/configure-security-tenant.sh and a tenant key/display name.

Deploy with scripts/deploy-security-gateway.sh and confirmation token REVINT_SECURITY_GATEWAY.
## Handover rules

- Prefer SSO for human users.
- Use machine service credentials only for trusted application integrations.
- Never share one human identity between people.
- Never trust a principal_key supplied by external JSON.
- Keep the Agent backend private and expose only approved ingress routes.
- Rotate external credentials without changing canonical business data.
- Do not enable shared multi-tenant deployments until tenant columns/RLS and cross-tenant isolation tests are implemented for every data domain.
- Do not commit secrets, API keys, OAuth secrets, cookies, or client certificates.

## Verification

Run scripts/verify-security-gateway.sh.

The verifier checks tenant-scoped SSO resolution, service-principal binding, duplicate route rejection, least privilege, ingress controls, and workflow identity-binding structure.

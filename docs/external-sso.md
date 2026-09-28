# Agent v2 — External Authentication / SSO

## Status

The external-authentication foundation is locally verified.

A real identity provider is **not** activated in the local deployment. The safe default remains:

```text
SSO_ENABLED=false
```

With SSO disabled, both the OAuth2 login surface and the SSO report route return `404`.

Production activation requires a real public domain, a trusted domain-matching TLS certificate, an OIDC client registered with the chosen identity provider, and explicit deployment confirmation.

## Trust boundary

The SSO path keeps authentication separate from authorization:

```text
User
  -> OIDC Identity Provider
  -> OAuth2 Proxy
  -> nginx auth_request
  -> trusted OIDC subject
  -> internal Agent v2 SSO webhook
  -> governance.resolve_external_principal()
  -> internal principal_key
  -> existing deterministic authorization
  -> governed KPI execution
```

The identity provider authenticates the person. The existing Agent v2 governance database remains authoritative for application identity, role assignment, KPI permissions, dimension/filter permissions, row limits, and own/department/all-business data scope.

Identity-provider groups or requester-supplied roles do not grant Agent v2 permissions.

## Stable external identity

OAuth2 Proxy uses the OIDC `sub` claim as the stable external subject.

Internal mapping is stored in the existing `governance.principal_registry` using `(identity_provider, external_subject)` and resolved through:

```sql
governance.resolve_external_principal(
  identity_provider,
  external_subject
)
```

The reporting runtime may execute this bounded function but still cannot directly read the underlying principal registry.

## No automatic provisioning

SSO does not create users, roles, departments, or permissions automatically.

An administrator first creates/onboards the normal internal principal and permissions, then links that existing principal to the external identity:

```bash
bash scripts/map-sso-principal.sh \
  --principal <existing-principal-key> \
  --provider <identity-provider-key> \
  --subject <stable-oidc-subject>
```

This prevents IdP-controlled claims from silently creating privileged application identities.

## Spoof resistance

The public SSO route never trusts `principal_key` from the request body.

After OAuth2 Proxy authenticates the session, nginx forwards only the trusted external provider and subject to the internal SSO webhook. The Agent workflow resolves the internal principal and overwrites any requester-supplied principal before the existing authorization gateway runs.

Local verification explicitly sends a body that claims an admin principal while authenticating a sales-rep external subject. The result is restricted to the mapped sales rep's own data.

## Routes

When SSO is enabled, the external routes are:

```text
/oauth2/*
/sso/report
```

The report route is POST-only.

The internal n8n SSO webhook is:

```text
/webhook/revint/v2/report-sso
```

It is protected by the separate internal header credential `X-Revint-Sso-Internal-Key`. That credential is stored encrypted in n8n and injected only by nginx. It is not a user-facing authentication mechanism.

The existing `/webhook/revint/v2/report` API-key route remains available separately for machine/integration use.

## OAuth2 Proxy

The deployment uses OAuth2 Proxy as a provider-neutral OIDC authentication gateway.

The runtime image is pinned by immutable digest. Current verified version:

```text
v7.15.4
```

The OAuth2 Proxy service has no host-published port, uses OIDC with `openid profile email`, identifies users by the OIDC `sub` claim, uses secure HTTP-only SameSite=Lax cookies, has a read-only filesystem, drops Linux capabilities, and uses `no-new-privileges`.

## Configuration

Required private environment values include:

```text
SSO_ENABLED
SSO_IDENTITY_PROVIDER_KEY
SSO_OIDC_ISSUER_URL
SSO_OIDC_CLIENT_ID
SSO_OIDC_CLIENT_SECRET
SSO_ALLOWED_EMAIL_DOMAINS
SSO_COOKIE_SECRET
SSO_INTERNAL_API_KEY
OAUTH2_PROXY_IMAGE
```

Do not commit these values.

The identity provider must register this redirect URI:

```text
<PUBLIC_HTTPS_ORIGIN>/oauth2/callback
```

## Local-safe deployment

Initialize the database resolver, encrypted internal credential, and SSO-capable Agent workflow without enabling a real external IdP:

```bash
bash scripts/deploy-sso-core.sh
```

This does not enable public SSO by itself.

## Production activation

After DNS, a trusted certificate, the public webhook URL, and a real OIDC application are configured, set:

```text
SSO_ENABLED=true
```

Then run:

```bash
bash scripts/deploy-external-sso.sh \
  --confirm REVINT_EXTERNAL_SSO
```

The activation script refuses to continue unless SSO is explicitly enabled, the OAuth2 Proxy image is digest-pinned, the issuer uses HTTPS, a real public domain and non-loopback ingress are configured, the HTTPS origin and n8n webhook URL that domain, the TLS certificate matches the domain, required OIDC secrets are present, and the explicit confirmation token is supplied.

## Verification

Run:

```bash
bash scripts/verify-external-sso.sh
```

Verification proves:

- external identity resolution without raw identity-table access
- encrypted internal SSO credential storage
- both report webhooks are registered
- bounded retries on the SSO principal lookup
- invalid internal SSO keys are rejected
- requester-supplied principal spoofing is ineffective
- unmapped external subjects are denied
- SSO-authenticated audit events record their authentication source
- the OAuth2 Proxy image/version is pinned and verified
- SSO routes remain closed while disabled
- real SSO activation requires explicit confirmation
- the full existing production-foundation regression chain remains green

## Production activation still pending

Local verification does not claim a successful login against a real production IdP.

That final deployment step requires the client's actual identity provider, DNS/domain, trusted certificate, redirect registration, client credentials, user-to-principal mappings, and a controlled end-to-end login test.

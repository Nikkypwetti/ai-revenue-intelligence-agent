# Agent V2 — Reference Client Deployment

The repository remains reusable. A client implementation is configuration plus isolated credentials, not a fork of the core.

## Current personal-business reference

The local reference deployment is intentionally private/local-only until a real client requires a public domain/VPS.

- deployment mode: isolated single client
- timezone: Africa/Lagos
- reporting currency: USD
- HubSpot: live read-only Deals adapter
- Salesforce: staged read-only Opportunity adapter; dedicated Agent V2 OAuth credential required before activation
- Airtable: staged read-only Opportunity adapter; provider blocked by the current monthly API billing limit
- Groq intent + grounded management summary: live
- public DNS/VPS/real OIDC: deferred

## Production rules

1. Never reuse Business OS/legacy n8n credentials inside Agent V2.
2. Source workflows read provider records and write canonical facts only through the Connector Writer gateway.
3. Provider unavailability, missing credentials, unsupported fields, or billing limits produce disabled/unavailable states, never fabricated zero values.
4. CRM write-back/routing is a separate approval-controlled extension and is not required for reporting-source activation.
5. Every client receives isolated configuration, credentials, RBAC, UAT evidence, backup/rollback evidence, and handover documentation.


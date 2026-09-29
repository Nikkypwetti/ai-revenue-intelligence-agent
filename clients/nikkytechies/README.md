# NikkyTechies — Agent V2 Client Implementation

This folder is the non-secret client overlay for deploying the reusable Revenue Intelligence Agent V2 against the owner's real/practice business systems.

## Deployment position

- Deployment model: one isolated Agent V2 instance for NikkyTechies.
- Runtime: local Docker deployment only for now.
- Public domain/VPS: deferred until a real client deployment requires internet access.
- Public SSO: remains disabled until a real domain, trusted TLS certificate and IdP application exist.
- AI: Groq intent and management-summary adapter is live-enabled through the dedicated encrypted Agent V2 credential.
- Core authorization: deterministic RBAC, KPI governance and PostgreSQL permissions remain authoritative.

## Source-of-truth matrix

| Domain | Source | Mode | Current status |
|---|---|---|---|
| Deals / pipeline / revenue | HubSpot | authoritative | live, read-only |
| Deals / opportunities | Salesforce | shadow validation | adapter-ready; dedicated Agent V2 OAuth credential still required |
| Lead intake / qualification | Airtable | authoritative for leads | adapter-ready; Airtable monthly API limit currently blocks live validation |
| Targets | Agent V2 / future source | not ready | do not return zero when unavailable |
| Activities / SLA | CRM / future source | not ready | do not return zero when unavailable |
| Forecasts | CRM / future source | not ready | do not return zero when unavailable |
| Subscriptions | billing/CRM / future source | not ready | do not return zero when unavailable |

## Why Salesforce starts in shadow mode

HubSpot and Salesforce can contain the same commercial opportunity. Agent V2 currently guarantees idempotency inside each connector using connector_key + source_record_id, but it does not yet claim cross-CRM entity resolution.

Therefore Salesforce must not feed canonical revenue totals at the same time as authoritative HubSpot until one of these is true:

1. HubSpot is explicitly replaced as the authoritative deal source; or
2. a governed cross-source identity/deduplication key is implemented and verified.

Shadow mode permits field mapping, freshness, stage mapping and record-count comparison without creating double-counted revenue.

## HubSpot live business mapping

Portal pipeline: `default`

Observed stage definitions:

| HubSpot value | Label | Canonical category |
|---|---|---|
| 5742274793 | New Lead | open |
| 5742274794 | Discovery Call Scheduled | open |
| 5742274795 | Proposal Sent | open |
| 5742274796 | Negotiating | open |
| 5742274798 | Deal Won | won |
| 5742274799 | Deal Lost | lost |

The runtime HubSpot adapter still derives won/lost from HubSpot's deterministic closed/won properties rather than trusting stage labels alone.

## Airtable business mapping

The existing lead-intake model contains fields such as:

- Full name
- Email
- Business type
- Notes / pain point
- Team size
- Budget range
- AI Score
- AI Qualified
- AI Package
- Follow-up due
- Last contacted
- Priority
- AI Reason
- AI Status
- Attachment Summary

Airtable is therefore treated as a lead/funnel and qualification system, not as a canonical revenue-deal source.

## Activation gates

Every source must pass the same four states before it can affect production metrics:

1. code-ready
2. dedicated credential connected
3. source mapping/data validated
4. live activation approved

Missing source domains remain unavailable. They must never be silently interpreted as zero.

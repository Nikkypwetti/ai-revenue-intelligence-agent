# First Client Implementation — Local Business Deployment

This document turns the reusable Agent V2 core into a real single-business client implementation using the owner's existing HubSpot, Salesforce Developer Edition, and Airtable CRM environments.

The reusable core remains source-neutral. Client-specific credentials, CRM field IDs, user mappings, stage labels, and data-readiness states belong to the isolated deployment and must not weaken the deterministic governance layer.

## Deployment boundary

Current deployment model:

- one isolated Agent V2 deployment for this business
- local Docker runtime only
- n8n exposed only on loopback
- no VPS
- no public domain
- no production OIDC activation
- no shared SaaS multi-tenancy

Public deployment, trusted TLS, DNS, and external OIDC remain intentionally deferred until a real client deployment justifies the infrastructure cost.

## Source-of-truth strategy

Agent V2 may read multiple systems, but every source passes through the same canonical contracts before KPI execution.

| Source | Intended role | Current status |
|---|---|---|
| HubSpot | Primary live deal/pipeline source | Live source verified; read-only connector already exists |
| Salesforce | Secondary CRM / RevOps implementation source | Mapping defined; dedicated Agent V2 read-only runtime adapter still requires local deployment |
| Airtable | Supporting operations CRM / lead-opportunity source | Connector contract added but kept inactive until API quota resets and live field schema is re-read |

No source receives direct reporting-table write permission.

## HubSpot implementation

### Live portal baseline

The connected HubSpot portal currently contains:

- one default deal pipeline
- 10 deals
- six configured stage values:
  - New Lead
  - Discovery Call Scheduled
  - Proposal Sent
  - Negotiating
  - Deal Won
  - Deal Lost
- one current deal owner
- USD as the configured deal currency option

The live source uses the existing `REVINT-V2-HUBSPOT-01` adapter.

### Canonical mapping

HubSpot fields map as follows:

| Canonical field | HubSpot field |
|---|---|
| deal_name | dealname |
| amount | amount |
| currency_code | deal_currency_code, with governed business-currency fallback when omitted |
| stage_name | dealstage |
| stage_category | deterministic `revint_stage_category` derived from `hs_is_closed` / `hs_is_closed_won` |
| sales_rep | hubspot_owner_id |
| lead_source | hs_analytics_source |
| created_at | createdate |
| expected_close_date | closedate |
| closed_at | closedate, forced to null for canonical open deals |
| source_updated_at | hs_lastmodifieddate |

The adapter does not trust customer-specific stage IDs to decide won/lost state.

### Live data-quality findings

The current portal contains three deals without an amount. Those records must remain rejected from revenue aggregation until corrected; they must not be silently interpreted as zero.

The live data also contains records whose displayed stage is `New Lead` while HubSpot's internal closed flag is true. Because Agent V2 intentionally trusts deterministic closure properties for canonical stage category, those records will classify as closed/lost unless the CRM data is corrected.

This is a useful real-client UAT finding: source data quality must be reviewed before management KPIs are treated as authoritative.

## Salesforce implementation

The Salesforce implementation is the AsterNova Developer Edition CRM.

### Verified Opportunity stage model

| Salesforce StageName | Canonical category |
|---|---|
| Discovery | open |
| Technical Review | open |
| Proposal Sent | open |
| Negotiation | open |
| Closed Won | won |
| Closed Lost | lost |

### Opportunity field mapping

| Canonical field | Salesforce field |
|---|---|
| deal_name | Name |
| amount | Amount |
| currency_code | governed USD default unless multi-currency is enabled |
| stage_name | StageName |
| stage_category | StageName through governed value map |
| sales_rep | OwnerId |
| lead_source | LeadSource |
| created_at | CreatedDate |
| expected_close_date | CloseDate |
| closed_at | CloseDate, forced null for canonical open opportunities |
| source_updated_at | LastModifiedDate |

Additional AsterNova fields remain useful for future reporting or qualification layers but are not required by the canonical deal contract:

- `Primary_Need__c`
- `Decision_Maker_Confirmed__c`
- `Lost_Reason__c`
- `Implementation_Priority__c`
- `Won_Date__c`
- `Lost_Date__c`
- `High_Value__c`

Salesforce remains a read-only Agent V2 source. Existing operational Salesforce automations and routing rules are not replaced by the reporting agent.

## Airtable implementation

The intended source is the business Airtable CRM with separate Leads and Opportunities tables.

The current Airtable API quota is exhausted, so the exact live field schema cannot be re-read safely today.

For that reason:

- `airtable_primary` is supported by the connector-config validator
- the first-client example contains explicit `CHANGE_ME_*` source-field placeholders
- the connector remains `active=false`
- the config validator rejects unresolved `CHANGE_ME_*` fields if someone attempts to activate the connector

This creates a fail-closed deployment path rather than guessing field names.

When Airtable API access resets:

1. read the Opportunities table schema
2. map the real field IDs/names into `config/connectors.local.json`
3. map Airtable stages to open/won/lost
4. run the connector-config verifier
5. deploy a dedicated read-only Airtable source adapter
6. ingest a bounded sample
7. compare canonical rows with Airtable source records
8. activate scheduled sync only after UAT passes

## Connector configuration

The public, secret-free first-client mapping reference is:

`config/first-client.connectors.example.json`

For the live local deployment create:

`config/connectors.local.json`

Never commit the local file when it contains client-specific identifiers that should stay private.

All public example connectors remain disabled by default.

## Security rules

The client implementation preserves the existing Agent V2 principle:

> AI interprets. Deterministic controls authorize. PostgreSQL permissions enforce the final security boundary.

Required controls:

- dedicated source credentials per client deployment
- CRM credentials read-only where possible
- no CRM token inside workflow JSON
- no source may write directly to `reporting.deals`
- canonical ingestion only through the approved Connector Writer gateway
- AI never chooses source credentials, roles, SQL, tables, tenant, or data scope
- missing data returns unavailable/rejected state rather than invented values
- caller identity is server-bound before AI interpretation
- audit and reliability handling remain separate from reporting credentials

## Local production-hardening plan

The following work does not require a VPS or public domain and should be completed locally:

1. static CI for JSON, shell syntax, connector policy, and secret-file checks
2. full runtime regression before every deployment
3. PostgreSQL 17 upgrade rehearsal using backup/restore and rollback checkpoints
4. encrypted backup verification and restore drill
5. optional off-device encrypted backup copy when an approved storage destination is available
6. connector failure tests
7. rate-limit and concurrency tests
8. dead-letter and circuit-breaker tests
9. incident notification routing
10. client UAT and handover evidence

Public ingress, public DNS, trusted production TLS, and real IdP login are deferred until a real external client deployment.

## UAT acceptance criteria

A source adapter is not considered live until all of these pass:

- authentication succeeds with a dedicated client credential
- source read scope is no broader than required
- connector is isolated from the protected legacy n8n instance
- field mappings are complete
- unknown stage values fail closed
- open records have canonical `closed_at = NULL`
- currency matches the governed client currency
- source-record ingestion is idempotent
- malformed records are rejected and counted
- watermark/cursor advances only after successful governed completion
- reporting reader cannot modify canonical facts
- connector writer cannot read or directly modify canonical facts
- audit writer cannot read reporting data
- Agent Core KPI regression passes after ingestion
- Groq outage does not break deterministic reporting
- no secret-like value appears in Git or workflow JSON

## Current implementation status

Completed:

- HubSpot source schema/records reviewed against the real connected portal
- first-client connector mapping pack added
- Salesforce AsterNova stage model mapped to the canonical contract
- Airtable connector type added to the configuration validator
- Airtable activation made fail-closed while field schema is unavailable
- static first-client verification script added
- GitHub CI workflow added for JSON/shell/client-config/secret-file checks

Requires local runtime access:

- create/import dedicated Agent V2 Salesforce read-only credential
- deploy and test Salesforce runtime adapter
- apply first-client connector mappings to the reporting database
- run live Salesforce ingestion/UAT
- re-read Airtable field schema after quota reset
- deploy Airtable runtime adapter
- PostgreSQL 17 rehearsal/cutover
- load/security/failure tests against the local containers
- off-device encrypted backup replication
- incident-notification activation

Requires future paid/public infrastructure:

- VPS or other always-on host
- public domain/DNS
- trusted production TLS
- real external OIDC/SSO client
- internet-facing production ingress

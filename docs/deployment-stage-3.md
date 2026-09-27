# Agent v2 — Stage 3 Connector & Data Contract Layer

## Status

Stage 3 adds a verified connector-normalization boundary on top of the merged Stage 1 and Stage 2 foundation.

The reference deployment now accepts differently shaped CRM deal records through deterministic, client-configured field mappings and normalizes them into one canonical `reporting.deals` contract.

This remains production-foundation work. No external CRM credential or live API connector is committed by this stage.

## Design goal

Different businesses can use HubSpot, Salesforce, PostgreSQL, Google Sheets, billing systems, or REST APIs without forcing the core Revenue Intelligence Agent to understand every provider's raw field names.

The boundary is:

```text
Source connector
      ↓
Client field/value mapping
      ↓
Controlled ingestion function
      ↓
Canonical reporting.deals
      ↓
Approved deterministic query template
      ↓
Read-only reporting credential
```

AI does not select source fields, write mappings, generate executable SQL, or receive database write authority.

## New database objects

### Governance

- `governance.connector_registry`
- `governance.connector_field_mapping`
- `governance.connector_value_mapping`
- `governance.query_templates`

Connector configuration is metadata only. Credentials and API tokens do not belong in these tables.

### Ingestion

- `ingestion.resolve_mapped_text(...)`
- `ingestion.ingest_deal_from_source(...)`

Only the public ingestion gateway is granted to the connector writer. The helper remains private.

### Reporting

- `reporting.deals`

The canonical deal contract contains:

- connector/source identity
- deal name
- amount
- currency
- source stage name
- canonical stage category: `open`, `won`, or `lost`
- sales rep
- lead source
- created timestamp
- expected close timestamp
- actual closed timestamp
- source updated timestamp
- source payload hash
- contract version
- ingestion timestamp

The first contract version intentionally supports deal/opportunity data because the currently governed KPIs are deal based.

## Deterministic mapping rules

Stage 3 supports only these transform keys:

- `text`
- `numeric`
- `uppercase`
- `timestamp`
- `value_map`

Stage categories require an explicit value map. Unknown source stages fail closed.

No connector configuration may provide executable code, SQL, or arbitrary transform expressions.

For open deals, canonical `closed_at` is forced to `NULL`. This handles CRM fields such as a shared close-date field that can represent an expected close while open and an actual close after closure.

Closed `won` and `lost` records require a closed timestamp.

## Currency boundary

Stage 3 does not perform foreign-exchange conversion.

The canonical deal currency must match the configured client currency in `governance.business_config`. A different currency is rejected until a governed FX policy is implemented.

## Least-privilege connector writer

Stage 3 adds:

- group role: `revint_connector_ingest`
- login role from `CONNECTOR_DB_WRITER_USER`

The connector writer can:

- connect to the reporting database
- execute `ingestion.ingest_deal_from_source(...)`

It cannot:

- read `reporting.deals`
- insert directly into `reporting.deals`
- read governance tables
- change connector mappings
- execute administrator migrations

The ingestion function is `SECURITY DEFINER`, uses a fixed search path, validates the connector contract, and performs a bounded upsert by `(connector_key, source_record_id)`.

## Approved deterministic query templates

The four Stage 2 KPI `query_key` values now resolve to active templates in `governance.query_templates`:

- `closed_won_revenue_v1`
- `open_pipeline_v1`
- `closed_won_deals_v1`
- `win_rate_v1`

All four read only from the canonical `reporting.deals` table and accept only the approved `start_at` / `end_at` runtime parameters.

Adding a connector therefore does not require rewriting these KPI queries.

## Connector configuration files

The public example is:

```text
config/connectors.example.json
```

For a real client, create:

```text
config/connectors.local.json
```

The local file is ignored by Git.

The configuration file contains field names, transform keys, activation state, and source-to-canonical value mappings only.

Do not place passwords, OAuth tokens, API keys, private keys, or n8n credential payloads in connector configuration.

## Initialize Stage 3

The private `deploy/.env` must contain separate connector-ingestion credentials.

Then run:

```bash
bash scripts/init-connector-contract.sh
```

Expected result:

```text
PASS: Stage 3 connector/data-contract schema and approved query templates initialized.
```

## Apply client connector mappings

After creating `config/connectors.local.json`:

```bash
bash scripts/apply-connector-config.sh
```

The script validates:

- config schema version
- connector type
- connector key format
- supported object type
- contract version
- canonical field names
- transform allowlist
- required core deal mappings
- stage-category value mappings
- absence of secret-like configuration keys

It then applies the mappings transactionally.

## Verify Stage 3

Run:

```bash
bash scripts/verify-stage3-contract.sh
```

The verification uses temporary HubSpot-shaped and Salesforce-shaped fixtures and removes them automatically.

It proves:

1. two different CRM source shapes map into one canonical deal contract
2. source-record upserts are idempotent
3. unmapped stage values fail closed
4. open opportunities do not retain an actual `closed_at`
5. connector writer can execute the ingestion gateway
6. connector writer cannot read or directly write reporting facts
7. reporting reader can read canonical deals
8. reporting reader cannot modify canonical deals
9. all active KPI query keys resolve to approved deterministic templates
10. canonical revenue and win-rate fixture calculations match expected values
11. Stage 2 security verification still passes
12. Stage 1 container health checks still pass

## Verified reference-deployment result

The local Agent v2 reference deployment passed every Stage 3 check.

Temporary verification connectors and deals were removed after the test.

The old local n8n instance on port 5678 was not modified. Agent v2 remains isolated on port 5681.

## Current limitations

Stage 3 does not yet provide:

- live HubSpot or Salesforce OAuth/API execution
- connector scheduling or incremental-sync cursors
- retries/dead-letter handling for source API failures
- multi-currency conversion
- account/contact canonical contracts
- external identity/RBAC
- HTTPS
- backup/restore automation
- monitoring and alerting
- upgrade/rollback automation

## Next implementation step

Integrate the verified Stage 3 contracts into the Agent v2 n8n runtime using the separate reporting-reader, audit-writer, and connector-writer credentials, then implement the first live connector adapter without changing the canonical reporting/query layer.

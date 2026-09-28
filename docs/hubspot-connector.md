# HubSpot Incremental Deal Connector

The HubSpot adapter is the first real CRM connector for Agent v2. It reuses the existing Stage 3 connector contract and canonical deal ingestion gateway rather than writing directly to reporting tables.

## Runtime flow

HubSpot Deals API
→ read-only n8n HubSpot credential
→ bounded incremental search
→ deterministic validation and stage classification
→ `hubspot_primary` connector mapping
→ controlled batch ingestion function
→ canonical `reporting.deals`
→ sync cursor + append-only audit
→ existing reliability/observability controls

The adapter never grants HubSpot permission to write CRM records. Agent v2 uses only a HubSpot private-app token with the minimum deal-read scope required for the source account.

### Currency normalization

The connector uses the governed business currency from Agent v2 as the deterministic default when HubSpot omits deal_currency_code. This covers deals stored in the account's default company currency without inventing a second currency value. If HubSpot supplies an explicit currency, it must still match the governed business currency or the record is rejected.

## Safe default

The committed connector template has `active=false`. The n8n workflow also has `active=false`.

Activation requires all of the following:

- `HUBSPOT_SYNC_ENABLED=true`
- a private `HUBSPOT_PRIVATE_APP_TOKEN`
- explicit command confirmation `REVINT_HUBSPOT_CONNECTOR`
- successful schema and regression verification

The token is imported directly into n8n encrypted credential storage as `REVINT | HubSpot Deals RO`. It must never be committed to Git or copied into workflow JSON.

## Incremental contract

The search window uses `hs_lastmodifieddate` with a persisted watermark and a five-minute overlap by default. The first run looks back 30 days by default.

Each request is limited to 200 deals. n8n pagination is capped at 50 pages, so a single execution cannot ingest more than 10,000 source records.

If a source record fails deterministic normalization, the completion watermark does not move beyond the earliest rejected update. This causes the problematic window to be revisited rather than silently skipping bad CRM data.

## Stage normalization

The adapter does not hard-code customer-specific HubSpot stage IDs for won/lost logic. It derives the canonical category from HubSpot's deterministic properties:

- `hs_is_closed_won=true` → `won`
- otherwise `hs_is_closed=true` → `lost`
- otherwise → `open`

The raw HubSpot `dealstage` value is retained as canonical `stage_name`. The derived `revint_stage_category` still passes through the existing governed value-mapping table before entering `reporting.deals`.

## Current limitation

The connected ChatGPT HubSpot account can be inspected for schema verification, but its connector credential is not transferred into n8n. The local Agent v2 runtime therefore remains unactivated until a dedicated HubSpot private-app token is added to `deploy/.env`.

Recommended private values:

```bash
HUBSPOT_SYNC_ENABLED=false
HUBSPOT_PRIVATE_APP_TOKEN=CHANGE_ME_USE_A_PRIVATE_APP_TOKEN
HUBSPOT_INITIAL_LOOKBACK_DAYS=30
HUBSPOT_SYNC_OVERLAP_SECONDS=300
```

To activate only after the token is configured:

```bash
bash scripts/deploy-hubspot-connector.sh --confirm REVINT_HUBSPOT_CONNECTOR
```

Do not run the activation command with a production CRM until the account's currency, deal fields, and expected sync window have been reviewed.

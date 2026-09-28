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

## Reusable client deployment

The connector is designed to be reused as a per-client deployment, not as a shared credential or shared tenant. The code, database contract, KPI layer, reliability controls, observability, and workflow templates stay the same; each client environment supplies its own HubSpot read credential, business currency, connector configuration, identity mappings, and network settings.

Recommended private values:

```bash
HUBSPOT_SYNC_ENABLED=false
HUBSPOT_PRIVATE_APP_TOKEN=CHANGE_ME_USE_A_READ_ONLY_SERVICE_KEY_OR_PRIVATE_APP_TOKEN
HUBSPOT_INITIAL_LOOKBACK_DAYS=30
HUBSPOT_SYNC_OVERLAP_SECONDS=300
EGRESS_DNS_PRIMARY=1.1.1.1
EGRESS_DNS_SECONDARY=8.8.8.8
```

The `HUBSPOT_PRIVATE_APP_TOKEN` variable name is retained for compatibility with the existing n8n credential type; it may hold a supported HubSpot read-only Service Key. For client networks, override the egress DNS values with the client's approved DNS resolvers when public resolvers are inappropriate.

Deployment is fail-closed. The script keeps connector governance disabled while it imports the encrypted credential and publishes workflows in isolated one-off n8n CLI containers. The long-running Agent v2 n8n service is restarted and health-checked before connector and reliability policies are enabled.

To activate only after the client's credential, currency, deal fields, and expected sync window have been reviewed:

```bash
bash scripts/deploy-hubspot-connector.sh --confirm REVINT_HUBSPOT_CONNECTOR
```

A live read-only HubSpot source has been used to validate this deployment path. Repository defaults remain disabled and no client credential is committed.

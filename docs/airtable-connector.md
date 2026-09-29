# Airtable Opportunity Connector

Workflow: `REVINT-V2-AIRTABLE-01 | Incremental Opportunity Sync`

This is a real importable read-only Airtable adapter built against n8n's current Airtable v2 `search` operation and `airtableTokenApi` credential.

It stays disabled until the Airtable monthly API quota resets and the live Opportunities schema is verified.

Required local settings:
- `AIRTABLE_BASE_ID`
- `AIRTABLE_TABLE_ID`
- `AIRTABLE_LAST_MODIFIED_FIELD`
- `AIRTABLE_CONNECTOR_CONFIG_FILE=config/connectors.local.json`
- dedicated PAT credential `REVINTAIRTABLE001 | REVINT | Airtable Opportunities RO`

The local connector config must replace every `CHANGE_ME_*` mapping with the real field/stage names. Deployment rejects unresolved placeholders.

The workflow uses a governed incremental window, Airtable formula filtering, deterministic circuit gating, controlled canonical batch ingestion, and completion/audit cursor updates. Any invalid source batch fails without advancing the cursor.

No Airtable create/update/delete node exists.

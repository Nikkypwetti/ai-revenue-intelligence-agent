# Salesforce Opportunity Connector — First Client / AsterNova

This adapter connects the existing AsterNova Salesforce Developer Edition CRM to Agent V2 as a read-only revenue source.

It does not replace Salesforce lead routing, deal approval, task automation, owner assignment, or other operational CRM workflows.

## Runtime flow

```text
Salesforce Opportunity
  -> dedicated Agent V2 Salesforce OAuth credential
  -> bounded LastModifiedDate SOQL
  -> deterministic stage/data validation
  -> salesforce_primary connector contract
  -> controlled canonical batch ingestion
  -> reporting.deals
  -> cursor + append-only audit
  -> existing 37-KPI semantic/RBAC layer
```

## Dedicated credential boundary

Expected n8n credential:

- Name: `REVINT | Salesforce Opportunities RO`
- Type: `salesforceOAuth2Api`

n8n generates the credential ID when OAuth is created in the UI. The repository workflow keeps `REVINTSALESFORCERO001` only as a template reference. At deployment, the script resolves exactly one encrypted credential by name/type and patches the temporary runtime workflow with the real n8n-generated credential ID before import.

The existing Business OS Salesforce credential must not be copied automatically.

Before activation, the Salesforce integration user/profile must be independently reviewed so it can read the required Opportunity fields but cannot modify CRM records through this Agent V2 integration.

Set `SALESFORCE_READONLY_CONFIRMED=true` only after that review.

## AsterNova Opportunity mapping

| Canonical field | Salesforce |
|---|---|
| deal_name | Name |
| amount | Amount |
| currency_code | governed deployment currency (USD in the reference client) |
| stage_name | StageName |
| stage_category | governed StageName value map |
| sales_rep | OwnerId |
| lead_source | LeadSource |
| created_at | CreatedDate |
| expected_close_date | CloseDate |
| closed_at | Won_Date__c / Lost_Date__c with CloseDate fallback |
| source_updated_at | LastModifiedDate |

Additional source context may be read for future governed reporting:

- `Primary_Need__c`
- `Decision_Maker_Confirmed__c`
- `Lost_Reason__c`
- `Implementation_Priority__c`
- `Won_Date__c`
- `Lost_Date__c`
- `High_Value__c`

## Stage governance

| StageName | Canonical |
|---|---|
| Discovery | open |
| Technical Review | open |
| Proposal Sent | open |
| Negotiation | open |
| Closed Won | won |
| Closed Lost | lost |

An unknown stage is rejected rather than guessed.

## Incremental boundary

The query is generated only from server-side code and uses a fixed:

- object: `Opportunity`
- field allowlist
- `LastModifiedDate` start/end window
- ascending sort
- `LIMIT 2000`

If Salesforce reports that more records remain (`done != true` / `nextRecordsUrl`), the execution fails closed rather than advancing the watermark and silently dropping records. A later pagination enhancement can increase throughput without changing the canonical contract.

## Data-quality rules

Records are rejected when:

- Opportunity ID is missing/oversized
- amount is missing/non-numeric/negative
- stage is not in the approved map
- LastModifiedDate is invalid
- a won/lost record cannot resolve a close timestamp

Rejected records prevent the cursor from moving past the earliest rejected update.

## Activation

Repository defaults remain disabled:

```text
SALESFORCE_SYNC_ENABLED=false
SALESFORCE_READONLY_CONFIRMED=false
```

After creating the dedicated n8n OAuth credential and reviewing the integration user's permissions:

```bash
SALESFORCE_SYNC_ENABLED=true
SALESFORCE_READONLY_CONFIRMED=true
SALESFORCE_INSTANCE_URL=https://<my-domain>.my.salesforce.com
```

Then deploy explicitly:

```bash
bash scripts/deploy-salesforce-connector.sh \
  --confirm REVINT_SALESFORCE_CONNECTOR
```

The deployment keeps connector governance disabled while workflows are imported/published, restarts only Agent V2 n8n, waits for health, and activates Salesforce sync governance only afterward.

## Current status

Repository implementation: complete and CI-verifiable.

Live local activation: pending Desktop access and creation/verification of the dedicated read-only Salesforce OAuth credential.

No public domain or VPS is required for local Salesforce connector validation.

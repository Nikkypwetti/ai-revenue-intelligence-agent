# Agent v2 — Stage 4 Runtime Integration & REST Connector

## Status

Stage 4 is locally verified on the isolated Agent v2 deployment.

It connects the Stage 2 least-privilege credentials and Stage 3 canonical data contract to a live n8n runtime workflow.

The first live connector is an authenticated REST deal-ingestion adapter.

Stage 4 remains local-only foundation work. It does not expose n8n or the ingestion endpoint to the public internet.

## Runtime boundary

```text
Authenticated REST POST
        ↓
n8n Webhook — header auth
        ↓
Reporting RO — load governed runtime configuration
        ↓
Deterministic request validation
        ↓
Connector Writer — controlled ingestion function only
        ↓
Canonical reporting.deals
        ↓
Reporting RO — verify canonical result
        ↓
Audit Writer — append ingestion event
        ↓
Bounded HTTP response
```
## n8n runtime credentials

Stage 4 uses four separate n8n credentials:

- `REVINT | Reporting RO` — reads approved reporting/governance data
- `REVINT | Audit Writer` — inserts audit events only
- `REVINT | Connector Writer` — executes the controlled ingestion gateway only
- `REVINT | Ingestion Header Auth` — authenticates the REST webhook

The database passwords and REST ingestion key remain in private runtime configuration.

`scripts/import-runtime-credentials.sh` streams credential JSON directly from environment values into the n8n import command.

The script does not create a plaintext credential file.

n8n encrypts imported credential data using the configured `N8N_ENCRYPTION_KEY`.

The verification script confirms all four credential records are encrypted and owned by the instance owner's personal project.

## REST endpoint

The verified local endpoint is:

```text
POST http://127.0.0.1:5681/webhook/revint/v2/deals
```

Authentication uses the header name:

```text
X-Revint-Ingest-Key
```
The header value is stored only in the ignored private `deploy/.env` file.

Requests without the correct header are rejected before workflow execution.

## Request contract

The adapter accepts one deal object per request.

Required fields:

- `source_record_id`
- `amount`
- `currency_code`
- `stage_name`
- `stage_category`

For `won` or `lost` deals, `closed_at` is also required.

Optional fields:

- `deal_name`
- `sales_rep`
- `lead_source`
- `created_at`
- `expected_close_date`
- `closed_at`
- `source_updated_at`

Allowed canonical stage categories are `open`, `won`, and `lost`.

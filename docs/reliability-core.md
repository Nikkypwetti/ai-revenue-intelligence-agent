# Agent v2 — Reliability Core

## Status

Locally verified on the isolated Agent v2 deployment.

This layer adds runtime reliability controls around the existing REST ingestion, report Agent, and Scheduled Intelligence workflows. It does not import the older sanitized error-handler workflow or reuse credentials from the protected local n8n instance.

## What this layer adds

- bounded three-attempt retries on safe PostgreSQL nodes
- a dedicated Agent v2 Error Trigger workflow
- deterministic terminal-failure classification
- idempotent runtime-failure and dead-letter persistence
- database-backed circuit breakers per runtime component
- half-open probe control after the recovery window
- conflict-safe audit writes for retryable audit nodes
- explicit `503`/skip behavior while a circuit is open

## Retry boundary

Retries are enabled only where replay is safe: governed reads, canonical source-record upserts, bounded reporting functions, and idempotent audit functions. The configured policy is three attempts with a 2-second delay.

The reliability handler does not automatically replay a completed business workflow after the retry budget is exhausted. Terminal failures are classified and dead-lettered instead.

## Circuit breaker

Each managed component has its own circuit state:

- `rest_ingestion`
- `agent_reporting`
- `scheduled_intelligence`

Three distinct terminal failures open the circuit. After the configured recovery window, one half-open probe is permitted. A successful bounded completion closes the circuit and resets the failure count; a failed half-open probe reopens it.

## Dead-letter and idempotency model

Terminal failures are stored once per deterministic workflow/execution/node identity. Repeated handling of the same terminal failure returns `duplicate_ignored` and does not increment the circuit again.

Every terminal incident creates at most one dead-letter row. The dead-letter payload contains bounded operational references only; raw request payloads, credentials, stack traces, and secrets are not persisted by this layer.

Audit nodes use `governance.record_reliable_audit_event`, which inserts by deterministic `event_id` with `ON CONFLICT DO NOTHING`. This makes n8n node retries safe without granting the audit-writer direct SELECT access.

## Runtime error workflow

`REVINT-V2-SYS-01` uses the n8n Error Trigger. The three managed runtime workflows point to it through their `errorWorkflow` setting.

The handler normalizes and redacts the terminal error, then calls the bounded `governance.record_terminal_failure` function through the existing Audit Writer credential.

## Initialize and deploy

```bash
bash scripts/deploy-reliability-core.sh
```

## Verify

```bash
bash scripts/verify-reliability-core.sh
```

Verification covers retry metadata, error-workflow routing, retryable/non-retryable classification, duplicate suppression, dead-letter persistence, circuit open/half-open/close behavior, audit-writer least privilege, protected ports, and the complete earlier regression chain.

## Deliberate limits

This milestone does not add external incident notifications, automatic dead-letter replay, or a new n8n API credential. Those actions should be added only with explicit operational policy and least-privilege credentials.
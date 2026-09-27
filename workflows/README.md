# n8n Workflows

This directory contains deployable Agent v2 runtime templates and portfolio-safe sanitized exports from the earlier Revenue Intelligence implementation.

## Agent v2 runtime templates

### REVINT-V2-REST-01 — Authenticated Deal Ingestion

`runtime-templates/REVINT-V2-REST-01.json`

The locally verified Stage 4 ingestion adapter that normalizes authenticated deal payloads into the canonical reporting contract.

### REVINT-V2-AGENT-01 — Governed Report Agent Core

`runtime-templates/REVINT-V2-AGENT-01.json`

The locally verified report execution core. It accepts authenticated report requests, interprets the four currently governed KPIs through a bounded deterministic fallback or a structured-intent contract, calls the PostgreSQL authorization/execution gateway, returns safe clarification or report responses, and writes bounded audit events.

A live LLM model credential is intentionally not embedded in this template. A future model adapter must produce the same structured-intent contract and remains downstream of the same deterministic authorization boundary.

### REVINT-V2-SCHEDULED-01 — Pipeline Intelligence

`runtime-templates/REVINT-V2-SCHEDULED-01.json`

The locally verified proactive pipeline workflow. It runs daily at 08:00 and weekly on Monday at 08:15 in the configured n8n timezone, generates a bounded pipeline-risk digest through the reporting-reader credential, and appends the result through the existing audit-writer credential.

It detects stale open records, missing expected close dates, and material open-pipeline movement against the prior snapshot. External Slack/email delivery is intentionally not configured yet.

### REVINT-V2-SYS-01 — Runtime Reliability Handler

`runtime-templates/REVINT-V2-SYS-01.json`

The locally verified Agent v2 terminal-failure workflow. The REST ingestion, reporting Agent, and Scheduled Intelligence workflows point to it through n8n's `errorWorkflow` setting after bounded node retries are exhausted.

It redacts and normalizes the terminal error, then records an idempotent runtime failure, dead-letter entry, and per-component circuit state through the existing Audit Writer credential. It does not automatically replay failed business workflows or require an n8n API key.

### REVINT-V2-OBS-01 — Runtime Observability

`runtime-templates/REVINT-V2-OBS-01.json`

The locally verified five-minute monitoring workflow. It builds a bounded runtime snapshot from governed component, circuit, failure, and dead-letter status through Reporting RO, then persists the snapshot through the existing Audit Writer credential using deterministic five-minute event IDs.

It uses bounded PostgreSQL retries and routes terminal failures through `REVINT-V2-SYS-01`. External notification delivery is intentionally not configured yet.

## Sanitized portfolio workflows

### REVINT-01 — Manager Request Orchestrator

`sanitized-workflow-exports/REVINT-01.sanitized.json`

Core reporting workflow responsible for:

- request normalization and validation
- structured AI intent interpretation
- KPI catalogue governance
- approved query resolution
- safe runtime parameters
- read-only PostgreSQL reporting
- result validation
- management-summary generation
- presentation routing
- Slack, Form, and API delivery
- audit logging

### REVINT-06 — Manager Form Gateway

`sanitized-workflow-exports/REVINT-06.sanitized.json`

Authenticated manager-facing Form intake and response workflow.

It submits requests into the same governed reporting pipeline used by other channels and displays either the approved report or a bounded safe rejection.

### REVINT-SYS-01 — Error Handler

`sanitized-workflow-exports/REVINT-SYS-01.sanitized.json`

Centralized operational error workflow responsible for:

- error normalization
- incident identification
- deterministic error classification
- recoverability decisions
- controlled retry/backoff
- escalation
- Slack-safe alert redaction
- dead-letter persistence
- audit traceability

## Security note

These are **sanitized portfolio exports**, not production backups.

Before publication, credential references and instance metadata were removed or redacted and the resulting JSON exports were checked for secret-bearing values.

The repository intentionally excludes:

- API keys and tokens
- passwords
- authentication secrets
- credential payloads
- `.env` files
- database dumps
- private local configuration
- raw n8n exports

The design principle remains:

> AI interprets intent. Deterministic controls authorize execution. PostgreSQL permissions enforce the final security boundary.

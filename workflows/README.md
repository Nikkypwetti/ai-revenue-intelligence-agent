# Sanitized n8n Workflow Exports

This directory contains portfolio-safe exports of the core workflows used by the AI Revenue Intelligence & Reporting Agent.

## Published workflows

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

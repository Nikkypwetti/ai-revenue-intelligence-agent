# Agent v2 — Monitoring & Observability

## Status

Locally verified on the isolated Agent v2 deployment.

This layer builds on the existing Stage 1 container health checks and Reliability records. It does not replace either system and does not copy raw audit data into a second store.

## Monitoring surfaces

The `observability` schema exposes four bounded read surfaces:

- `component_status` — one row per managed runtime component
- `runtime_status` — one-row overall runtime summary
- `alert_ready` — deterministic circuit/failure/dead-letter alert rows
- `snapshot_history` — persisted five-minute health snapshots

The Reporting RO credential can read these surfaces but still cannot read the raw `audit.runtime_failures` or `audit.dead_letter` tables.

## Component status

Managed components are:

- `rest_ingestion`
- `agent_reporting`
- `scheduled_intelligence`
- `observability`

Each component exposes circuit state, consecutive failures, one-hour and 24-hour failure counts, 24-hour success-event count, open dead-letter backlog, last success/failure timestamps, and a deterministic operational status: `healthy`, `degraded`, `blocked`, or `unknown`.

`blocked` means the component circuit is open or half-open. `degraded` means the circuit is closed but recent terminal failures or unresolved dead letters still require attention.

## Alert-ready data

`observability.alert_ready` generates bounded rows for:

- blocked/open or half-open circuits — critical
- unresolved dead-letter backlog — warning, critical at three or more
- terminal failures in the last hour — warning, critical at three or more

No external Slack, email, PagerDuty, or other notification credential is embedded. A later notification adapter can consume these rows without gaining access to raw failure payloads.

## Five-minute heartbeat

`REVINT-V2-OBS-01` runs every five minutes in the configured n8n timezone. It builds a bounded runtime snapshot through Reporting RO and stores it through the existing Audit Writer credential using deterministic five-minute event IDs.

The workflow itself uses bounded retries and routes terminal failures through `REVINT-V2-SYS-01`, so monitoring failures enter the same Reliability model.

## Initialize and deploy

```bash
bash scripts/deploy-observability-core.sh
```

## Verify

```bash
bash scripts/verify-observability-core.sh
```

Verification covers view/function permissions, five-minute workflow publication, deterministic degraded/blocked transitions, alert-ready rows, snapshot persistence, old/new n8n isolation, and the full Reliability → Scheduled Intelligence → Agent → Identity → Semantic → Stage 4 → Stage 3 → Stage 2 → Stage 1 regression chain.

## Deliberate limits

This milestone provides monitoring data and alert-ready status, not external alert delivery. Container/process health remains in the existing Stage 1 health checks; this layer focuses on application/runtime health and reliability state.
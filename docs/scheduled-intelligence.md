# Agent v2 — Scheduled Intelligence

## Status

The first proactive intelligence layer is designed for the isolated Agent v2 runtime and uses the existing reporting-reader and audit-writer credentials.

## What it adds

The scheduled layer generates governed daily and weekly pipeline-risk digests without waiting for a manager question.

Current deterministic checks are:

- stale open deals, using the configured `stale_deal_days`
- open deals missing expected close dates
- material open-pipeline movement versus the previous snapshot of the same cadence
- seven-day closed-won deal count and revenue context
- top five highest-value stale open deals

The default material-movement threshold is 20% and is stored in `governance.intelligence_rule`, so it can be changed without editing workflow logic.

## Important data limitation

The canonical deal model does not currently contain a CRM activity timestamp.

The stale-deal check therefore uses:

1. `source_updated_at`
2. `created_at`
3. `ingested_at`

in that order.

This is a **source-record freshness proxy**, not a claim that a sales rep has had no activity.

Pipeline coverage is also intentionally not calculated yet. The business configuration contains a minimum coverage ratio, but the canonical model does not yet contain a governed revenue target/quota fact. The system will not invent that denominator.

## Schedule

`REVINT-V2-SCHEDULED-01` contains two Schedule Trigger nodes:

- daily at 08:00
- weekly on Monday at 08:15

The workflow uses the n8n instance timezone, which is configured from the client deployment timezone (`GENERIC_TIMEZONE` / `TZ`).

For the current local deployment, that timezone is `Africa/Lagos`.

## Security boundary

The schedule workflow reuses:

- `REVINT | Reporting RO` to execute only `governance.build_scheduled_intelligence`
- `REVINT | Audit Writer` to append the generated digest to `audit.agent_events`

No Slack, email, or old-instance credential is reused.

The reporting credential still has no direct write privilege on reporting/governance tables.

## Persistence

Each generated digest is appended as:

- `event_type = scheduled_intelligence_generated`
- `stage = scheduled_intelligence`
- `actor = n8n_scheduled_intelligence`

The next run can compare the current open-pipeline value with the most recent prior audit event of the same cadence.

## Delivery boundary

This milestone generates and records proactive intelligence automatically.

External Slack/email delivery is intentionally not enabled until an Agent v2 delivery credential and destination are configured. This avoids copying credentials from the protected old n8n instance.

## Initialize

```bash
bash scripts/init-scheduled-intelligence.sh
```

## Deploy

```bash
bash scripts/deploy-scheduled-intelligence.sh
```

## Verify

```bash
bash scripts/verify-scheduled-intelligence.sh
```

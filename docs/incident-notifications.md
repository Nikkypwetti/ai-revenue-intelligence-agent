# Agent V2 — Governed Incident Notifications

This layer delivers operational incidents from the existing bounded observability surfaces. It is deliberately separate from manager report delivery.

## Source of incidents

The workflow reads only `observability.alert_ready`, which already emits bounded alerts for:

- open / half-open circuits
- unresolved dead-letter backlog
- recent terminal failures

It does not read raw request payloads, stack traces, credentials, or raw dead-letter payloads.

## Workflow

`REVINT-V2-INCIDENT-01 | Governed Incident Notifications`

Flow:

```text
5-minute schedule
  -> get_pending_incident_notifications()
  -> bounded incident message
  -> dedicated Slack incident credential
  -> record delivery state + audit
```

There is no public webhook.

## Separate credential

Incident delivery uses:

- ID: `REVINTSLACKINCIDENT001`
- Name: `REVINT | Slack Incidents`

It does not use `REVINTSLACKREPORT001`, the manager-report delivery credential.

## Trusted destination

The Slack channel ID is stored in `governance.incident_notification_config`.

AI, external callers, and alert payloads cannot choose a destination.

## Noise control

`audit.incident_notification_state` records the last successful notification for each `alert_key`.

A still-active alert becomes pending when:

- it has never been notified, or
- severity escalates, or
- the configured cooldown has elapsed

Default cooldown: one hour.

Default minimum severity: warning.

## Failure behavior

Slack delivery retries twice.

If provider delivery still fails, n8n routes the terminal workflow failure through `REVINT-V2-SYS-01` as component `incident_notifications`, so notification failures themselves participate in the reliability/circuit/dead-letter model.

The successful notification state is recorded only after provider delivery succeeds.

## Safe default

Repository defaults:

```text
INCIDENT_SLACK_ENABLED=false
INCIDENT_MIN_SEVERITY=warning
INCIDENT_COOLDOWN_SECONDS=3600
```

Activation requires:

1. dedicated incident Slack token
2. trusted incident channel ID/name
3. explicit confirmation token
4. encrypted n8n credential import
5. healthy Agent V2 runtime

## Activation

Private `deploy/.env` values:

```bash
INCIDENT_SLACK_ENABLED=true
INCIDENT_SLACK_ACCESS_TOKEN=<private token>
INCIDENT_SLACK_CHANNEL_ID=<trusted channel id>
INCIDENT_SLACK_CHANNEL_NAME=<human label>
INCIDENT_MIN_SEVERITY=warning
INCIDENT_COOLDOWN_SECONDS=3600
```

Then:

```bash
bash scripts/deploy-incident-notifications.sh \
  --confirm REVINT_INCIDENT_NOTIFICATIONS
```

No public domain or VPS is required for local Slack incident validation.

## Current status

Repository implementation and static verification: ready.

Live activation: pending a dedicated incident Slack destination/token and local Desktop runtime access.

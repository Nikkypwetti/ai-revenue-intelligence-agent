# Agent V2 — Local Production Hardening Without VPS/Domain

This stage completes the production work that can be done on the current laptop before paying for public infrastructure.

## Scope

Included now:

- PostgreSQL 17 restore rehearsal
- bounded local report API load testing
- encrypted off-device backup replication
- first-client CRM implementation/UAT
- existing reliability, observability, dead-letter, backup/recovery, rollback and Groq fail-soft controls

Intentionally deferred:

- VPS / always-on host
- public domain/DNS
- trusted public TLS
- public ingress
- real external OIDC/SSO client

Those are deployment-environment requirements, not blockers for validating the reusable Agent V2 architecture locally.

## PostgreSQL 17 rehearsal

The normal upgrade controller intentionally blocks PostgreSQL major upgrades. That guard remains correct.

Use the dedicated non-destructive rehearsal instead:

```bash
bash scripts/rehearse-postgres17-upgrade.sh \
  --confirm REVINT_PG17_REHEARSAL
```

The rehearsal:

1. selects a verified Agent V2 backup
2. runs the existing backup/recovery verifier first
3. pulls PostgreSQL 17 in isolated temporary containers
4. restores the n8n database into PostgreSQL 17
5. restores the reporting database into PostgreSQL 17
6. verifies the n8n workflow table
7. verifies governance/reporting/audit schemas
8. removes the temporary containers
9. never edits `deploy/.env`
10. never touches the live PostgreSQL 16 volumes

A successful rehearsal proves backup portability to PostgreSQL 17. It does **not** automatically perform the live major-version cutover.

The final live PostgreSQL 17 cutover should only happen after the rehearsal passes and a fresh release checkpoint/backup exists.

## Bounded local load test

Run only against the local authenticated report endpoint:

```bash
bash scripts/load-test-report-api.sh \
  --total 40 \
  --concurrency 4 \
  --confirm REVINT_LOCAL_LOAD_TEST
```

Safety limits:

- maximum total requests: 200
- maximum concurrency: 20
- structured intent is used by default, avoiding unnecessary LLM cost
- test fails on any 5xx response
- test fails below 95% success
- no source/CRM mutation occurs

This validates the report gateway and governed execution path without requiring a public domain.

## Encrypted off-device backup

Local backups already protect both databases and the n8n data volume. They are not sufficient against laptop loss/disk failure.

The new replication script encrypts the completed backup **before** upload.

Requirements:

- `age`
- `rclone`
- an age recipient public key
- an rclone remote

Example using a personal Google Drive rclone remote:

```bash
export BACKUP_AGE_RECIPIENT='age1...'
export BACKUP_RCLONE_REMOTE='gdrive:revint-agent-backups'

bash scripts/replicate-backup-offsite.sh \
  --confirm REVINT_OFFSITE_BACKUP
```

The age private key must be stored separately from both the laptop backup and the remote destination.

The script uploads only:

- `<timestamp>.tar.gz.age`
- `<timestamp>.tar.gz.age.sha256`

It does not upload the plaintext backup archive.

## Incident notifications

Agent V2 already exposes bounded `observability.alert_ready` rows for:

- blocked/open circuits
- unresolved dead letters
- repeated terminal failures

The external incident channel should stay separate from normal report delivery.

Recommended production policy:

- critical circuit/open failures → Slack incident channel
- dead-letter backlog → Slack incident channel
- repeated notification failure → dead letter + local observability state
- no raw request payloads or secrets in incident messages
- destination must come from trusted governance/configuration, never from AI or caller input

The actual local n8n incident workflow requires runtime access to deploy and a dedicated notification credential. It must not reuse the normal report-delivery Slack credential unless the same operational ownership is intentionally approved.

## First-client CRM rollout

### HubSpot

Current live source reviewed:

- 10 deals
- one pipeline
- USD
- one current owner
- three records missing amount
- multiple displayed `New Lead` records with internal closed state

Before calling HubSpot revenue KPIs authoritative, correct or explicitly exclude the source-data issues.

### Salesforce

AsterNova mapping is ready:

- Discovery → open
- Technical Review → open
- Proposal Sent → open
- Negotiation → open
- Closed Won → won
- Closed Lost → lost

The Agent V2 Salesforce connection should be read-only and should not replace the existing routing/approval automations.

### Airtable

Airtable remains inactive until API quota resets and the live Opportunities schema can be read.

The connector configuration now rejects activation if unresolved `CHANGE_ME_*` field placeholders remain.

## Definition of local production-ready

Without VPS/domain, the local deployment can be considered operationally ready for portfolio/internal use when:

- full Agent V2 regression passes
- Groq intent/summary and fail-soft tests pass
- HubSpot live sync UAT passes with known data-quality exceptions documented
- Salesforce read-only sync UAT passes
- Airtable field mapping and read-only sync UAT pass after quota reset
- PostgreSQL 17 rehearsal passes
- backup restore drill passes
- encrypted off-device backup replication passes
- bounded load test passes
- dead-letter/circuit failure tests pass
- incident notification workflow passes
- documentation/handover stays current

Public production readiness still additionally requires the deferred domain/TLS/SSO/VPS work.

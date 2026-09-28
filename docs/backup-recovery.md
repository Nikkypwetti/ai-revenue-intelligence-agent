# Agent v2 — Backup & Recovery

## Status

Locally verified on the isolated Agent v2 deployment.

This layer adds recoverable backups for the Agent v2 n8n application state, reporting database, and n8n persistent data volume without modifying the protected old local n8n installation.

## Backup contents

Each completed backup directory contains:

- `n8n-db.dump` — custom-format PostgreSQL dump of the Agent v2 n8n database
- `reporting-db.dump` — custom-format PostgreSQL dump of the governed reporting database
- `n8n-data.tar.gz` — archive of the Agent v2 n8n persistent data volume
- `manifest.env` — secret-free runtime/recovery metadata
- `SHA256SUMS` — SHA-256 integrity checks for every artifact

Backups are created under `./backups/<UTC timestamp>/` by default. The entire `backups/` directory is Git-ignored.

Backup files are created with owner-only permissions through `umask 077`.

## Encryption-key boundary

The actual `N8N_ENCRYPTION_KEY` is **not** copied into a backup.

The manifest stores only its SHA-256 fingerprint. Recovery verification refuses to continue when the active encryption key does not match that fingerprint.

The real encryption key and the other values from `deploy/.env` must therefore be protected separately, such as in a password manager or another secure secret escrow.

Without the original n8n encryption key, restored encrypted n8n credentials may be unreadable.

## Create a backup

```bash
bash scripts/backup-agent-v2.sh
```

The backup command can still capture the n8n persistent data volume when the Agent v2 n8n application container is stopped; it uses a one-off container mounted to the same volume rather than depending on the running application process.

The backup command:

1. acquires an exclusive backup lock
2. requires both PostgreSQL services to be running
3. dumps both PostgreSQL databases in custom format
4. archives the n8n persistent data volume
5. validates both PostgreSQL archives and the tar archive
6. writes secret-free recovery metadata
7. writes SHA-256 checksums
8. atomically promotes the completed backup directory
9. applies the configured retention policy

Default retention is 14 days. Override with `BACKUP_RETENTION_DAYS`.

## Recovery verification

```bash
bash scripts/verify-backup-recovery.sh
```

Or verify a specific backup:

```bash
bash scripts/verify-backup-recovery.sh backups/20260928T055711Z
```

Verification never overwrites the live databases. It:

- validates all checksums
- verifies the n8n encryption-key fingerprint
- checks both PostgreSQL archive catalogues
- rejects unsafe archive paths
- creates temporary verification databases
- restores the n8n database into an isolated database
- restores the reporting database into an isolated database
- confirms required n8n tables
- confirms governed reporting/audit/observability objects
- confirms four active KPI definitions
- extracts the n8n data archive into a temporary directory
- deletes every temporary verification database/directory afterward

## Live restore

A live restore is intentionally guarded.

```bash
bash scripts/restore-agent-v2.sh \
  --backup backups/<timestamp> \
  --confirm REVINT_AGENT_V2_LIVE_RESTORE
```

Before touching live data, the script:

1. verifies the selected backup
2. checks database names and the encryption-key fingerprint
3. creates a mandatory fresh pre-restore backup

The restore then stops only the Agent v2 n8n application container, recreates and restores both Agent v2 PostgreSQL databases, replaces the Agent v2 n8n data volume contents, starts the stack, and runs the health check.

The protected host-level n8n installation and its `~/.n8n/database.sqlite` are not part of this restore path.

A live restore is not run automatically during routine verification because it is intentionally destructive to the current Agent v2 state. If a live restore fails after the application has been stopped, n8n is deliberately left stopped rather than being started against a potentially partial restore; the script prints the mandatory pre-restore backup path for controlled recovery.

## Daily local backup schedule

For the current laptop deployment, cron is used because the system cron daemon is available while the user systemd timer interface is not reliably available.

Install the idempotent daily schedule:

```bash
bash scripts/install-backup-cron.sh
```

Default schedule:

```text
02:30 local system time, every day
```

The job writes its log to `backups/backup.log`.

Remove the schedule with:

```bash
bash scripts/uninstall-backup-cron.sh
```

If the laptop is powered off at 02:30, cron will not replay that missed run. When the project moves to an always-on VPS, use a persistent systemd timer or the hosting provider's backup scheduler.

## Recovery objectives

For the current local deployment:

- backup cadence: daily when the laptop is running
- local retention: 14 days by default
- restore verification: isolated temporary databases and archive extraction
- secret recovery: separate protected secret escrow required
- old local n8n: excluded from Agent v2 backup and restore

These are local-production recovery controls, not an off-site disaster-recovery guarantee. A future VPS deployment should add encrypted off-site copies and provider-level volume/database snapshots.

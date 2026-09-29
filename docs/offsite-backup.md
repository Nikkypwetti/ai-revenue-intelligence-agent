# Agent V2 — Encrypted Off-site Backup Replication

Local Agent V2 backups are created by `scripts/backup-agent-v2.sh` and verified before replication.

Off-site replication is deliberately disabled by default. It requires:

- `age` for public-key encryption
- `rclone` configured for a private remote such as Google Drive, S3-compatible storage, or another approved provider
- an `age` recipient whose private key is stored separately from the laptop and remote backup location

The replication script verifies the local backup checksums, streams the backup into an encrypted archive, uploads the encrypted archive plus its checksum, and confirms both remote objects exist.

No database password, n8n encryption key, OAuth token, or CRM credential is embedded in the backup script or Git repository.

A real client handover must record who owns the decryption key, the remote retention policy, the recovery drill date, and the approved storage jurisdiction.


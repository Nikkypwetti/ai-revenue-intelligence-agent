# Agent v2 — Upgrade & Rollback Controls

## Status

Locally verified on the isolated Agent v2 deployment.

This layer makes runtime upgrades checkpoint-first, digest-pinned, health-gated, and recoverable through the existing Backup & Recovery controls.

## Immutable runtime images

Docker Compose now consumes:

- `N8N_IMAGE`
- `POSTGRES_IMAGE`

Both values must be immutable `@sha256:` image references.

The readable variables `N8N_VERSION` and `POSTGRES_VERSION` remain release/compatibility labels, but they are not the deployment authority. The image digest is authoritative.

This prevents a mutable tag such as `postgres:16-alpine` from silently changing the deployed image during an ordinary Compose operation.

During verification, pulling the same textual `16-alpine` tag resolved to a newer image running PostgreSQL 16.15 and caused database-container recreation. After digest pinning, repeating the same resolved upgrade caused zero container recreation.

## Release checkpoint

Create a checkpoint manually with:

```bash
bash scripts/create-release-checkpoint.sh
```

A checkpoint is stored under:

```text
backups/checkpoints/<UTC timestamp>/
```

It contains owner-only, checksum-protected metadata for:

- source Git commit
- Docker Compose file checksum
- n8n version label
- PostgreSQL version label
- immutable n8n deployment image
- immutable PostgreSQL deployment image
- exact Docker image IDs
- repo digests
- verified pre-change backup path

Checkpoint creation also checks that the running containers already match the configured immutable image pins. Runtime/image drift fails closed.

## Upgrade preflight

Dry-run:

```bash
bash scripts/upgrade-agent-v2.sh \
  --target-n8n 2.35.7 \
  --target-postgres 16-alpine \
  --dry-run
```

The preflight validates:

- current deployment health
- immutable current image pins
- exact n8n semantic-version input
- explicit PostgreSQL target tag
- PostgreSQL major-version compatibility

Automatic PostgreSQL major upgrades are rejected. A future major upgrade requires a dedicated database migration plan rather than reusing the normal release controller.

## Confirmed upgrade

```bash
bash scripts/upgrade-agent-v2.sh \
  --target-n8n <exact-version> \
  --target-postgres <explicit-tag> \
  --confirm REVINT_AGENT_V2_UPGRADE
```

The controller:

1. verifies the current runtime is healthy
2. creates and verifies a release checkpoint and backup
3. pulls the requested target tags without changing the running deployment
4. resolves those tags to immutable repo digests
5. records the resolved target digests in the checkpoint
6. writes the immutable target refs into the private `deploy/.env`
7. applies Compose with `--wait`
8. verifies the running image IDs match the resolved target images
9. runs the complete Backup & Recovery regression chain

If the upgrade does not complete, the script prints the exact checkpoint and rollback command.

## Rollback dry-run

```bash
bash scripts/rollback-agent-v2.sh \
  --checkpoint backups/checkpoints/<timestamp> \
  --dry-run
```

Dry-run verifies:

- checkpoint checksums
- checkpoint format
- project identity
- immutable checkpoint image refs
- PostgreSQL major compatibility
- the checkpoint recovery backup

It does not alter the deployment.

## Confirmed rollback

```bash
bash scripts/rollback-agent-v2.sh \
  --checkpoint backups/checkpoints/<timestamp> \
  --confirm REVINT_AGENT_V2_ROLLBACK
```

Rollback:

1. verifies the checkpoint and recovery backup
2. pulls the exact checkpoint image digests
3. verifies their Docker image IDs
4. restores the checkpoint version labels and immutable image refs
5. invokes the guarded live restore against the checkpoint backup
6. verifies the running container image IDs exactly match the checkpoint
7. runs the complete regression chain

The existing live-restore control still creates a mandatory pre-restore backup before changing data.

## Verification

Run:

```bash
bash scripts/verify-upgrade-rollback.sh
```

The verifier covers:

- immutable Compose image refs
- running-image drift detection
- format-2 checkpoint checksums and permissions
- upgrade dry-run
- PostgreSQL-major rejection
- upgrade/rollback confirmation guards
- rollback dry-run
- zero recreation when resolved digests are unchanged
- old n8n 5678 / Agent v2 5681 isolation
- complete Backup & Recovery and earlier regression chain

A destructive rollback is not executed during routine verification. The rollback path is validated through checkpoint/backup recovery drills, exact digest validation, guarded restore integration, and dry-run controls.

# Agent v2 — Stage 1 Deployment Foundation

## Status

**Stage 1 scope:** reproducible single-business infrastructure foundation.

This stage packages the existing Revenue Intelligence Agent architecture into a repeatable Docker deployment without changing the governed reporting logic.

It is **not yet a complete production release**. HTTPS, production identity/RBAC, client-specific connector configuration, automated backups/restore tests, monitoring, and upgrade/rollback procedures are later stages.

## What Stage 1 adds

- pinned n8n runtime
- dedicated PostgreSQL database for n8n state
- separate PostgreSQL reporting database
- persistent Docker volumes
- database and n8n health checks
- local-only n8n port binding
- environment-based secret/configuration handling
- separate private database network and n8n egress network
- deployment validation and health-check scripts

## Security boundary

The public repository must never contain real passwords, tokens, API keys, database dumps, or unsanitized n8n credential data.

The existing files under `workflows/sanitized-workflow-exports/` remain portfolio-safe examples. They are not production backups and should not be treated as a source of live credentials.

## Prerequisites

- Docker Engine
- Docker Compose v2
- at least 2 GB available RAM for a small test deployment
- a secure password manager for generated secrets

Check:

```bash
docker --version
docker compose version
```

## 1. Create the local environment file

From the repository root:

```bash
cp deploy/.env.example deploy/.env
```

Generate independent secrets. For example:

```bash
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
```

Use separate generated values for:

- `N8N_DB_PASSWORD`
- `N8N_ENCRYPTION_KEY`
- `REPORTING_DB_ADMIN_PASSWORD`

Do not reuse passwords.

The n8n encryption key must remain stable and must be backed up securely. Changing it after credentials are stored can make those credentials unreadable.

## 2. Validate configuration

```bash
bash scripts/validate-deployment.sh
```

Expected result:

```text
PASS: Docker Compose configuration is valid and secret placeholders were replaced.
```

## 3. Start the Stage 1 stack

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.yml up -d
```

## 4. Verify health

```bash
bash scripts/healthcheck.sh
```

The script checks:

- `n8n-db`
- `reporting-db`
- `n8n`

Expected final line:

```text
PASS: Stage 1 deployment health checks passed.
```

## 5. Open n8n

Stage 1 intentionally binds n8n only to the local loopback interface:

```text
http://127.0.0.1:5678
```

Do not expose this Stage 1 configuration directly to the public internet.

## Persistence test

Create a harmless test workflow or note in n8n, then restart the stack:

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.yml restart
```

Run the health check again and confirm the test item still exists.

This verifies that the named volumes are retaining application and database state across container restarts.

## Stop the stack

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.yml down
```

Do **not** add `-v` unless you intentionally want to delete the named volumes and their data.

## Database separation

Stage 1 deliberately uses two PostgreSQL databases:

- `n8n-db` — n8n application state, workflow metadata, and encrypted credential records
- `reporting-db` — revenue reporting data and the future governed KPI/query layer

This prevents the automation platform's own application database from becoming the business reporting database.

Stage 2 will add dedicated reporting roles so production workflows can use least-privilege credentials instead of the reporting database administrator.

## Existing local n8n installation

This deployment is separate from a host-level n8n installation using `~/.n8n`.

Do not point the Docker deployment at an existing local `database.sqlite` as part of Stage 1. Workflow migration will be handled explicitly so the old environment remains recoverable.

## Stage 1 acceptance criteria

Stage 1 is complete only after all of these are verified on the target machine:

1. `docker compose config --quiet` succeeds.
2. All three services start.
3. Both PostgreSQL services report healthy.
4. n8n reports healthy.
5. n8n opens only on the configured loopback port.
6. State survives a container restart.
7. No real secrets are tracked by Git.
8. The existing local n8n environment remains unchanged.

## Next stage

**Stage 2 — Client Configuration & Reporting Security**

The next build will add:

- company/business configuration
- timezone, currency, fiscal calendar and pipeline thresholds
- versioned KPI catalogue
- dedicated read-only reporting role
- separate control/audit write role
- client-specific configuration without changing core workflows

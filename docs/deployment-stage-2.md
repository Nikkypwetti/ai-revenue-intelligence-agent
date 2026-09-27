# Agent v2 — Stage 2 Client Configuration & Reporting Security

## Status

Stage 2 adds the first client-specific configuration and database permission boundary on top of the verified Stage 1 deployment. The database security layer has been locally verified on the reference deployment.

This stage is **not yet a full production release**. Public HTTPS, external identity/RBAC, backup/restore automation, monitoring, upgrade/rollback, connector onboarding, and full workflow migration remain later stages.

## What Stage 2 adds

- client/company configuration stored outside workflow logic
- timezone, currency, fiscal-year start, stale-deal threshold, and minimum pipeline coverage
- versioned KPI catalogue
- dedicated read-only reporting role
- dedicated governance read role
- dedicated audit insert role
- separate login credentials for report reads and audit writes
- repeatable database initialization and client configuration scripts

## Permission model

### Reporting reader

The n8n reporting credential should use `REPORTING_DB_READER_USER`.

It receives:

- `SELECT` on the `reporting` schema
- `SELECT` on approved `governance` configuration tables
- no write access to reporting facts
- no audit-write permission

### Audit writer

The audit credential should use `AUDIT_DB_WRITER_USER`.

It receives:

- `INSERT` on `audit.agent_events`
- no reporting-table read privilege
- no governance modification privilege

### Administrator

`REPORTING_DB_ADMIN_USER` is reserved for migrations and controlled administration.

Do not use the administrator credential inside normal reporting workflows.

## New environment values

Add these values to the private `deploy/.env` file:

```text
REPORTING_DB_READER_USER=revint_agent_reader
REPORTING_DB_READER_PASSWORD=<generated secret>
AUDIT_DB_WRITER_USER=revint_audit_writer
AUDIT_DB_WRITER_PASSWORD=<different generated secret>

CLIENT_COMPANY_NAME=<business name>
CLIENT_TIMEZONE=<IANA timezone>
CLIENT_CURRENCY=<ISO 4217 code>
CLIENT_FISCAL_YEAR_START_MONTH=<1-12>
CLIENT_STALE_DEAL_DAYS=<positive integer>
CLIENT_MIN_PIPELINE_COVERAGE=<positive decimal>
```

Generate separate passwords and never commit the private `.env`.

## Initialize Stage 2 security

With the Stage 1 stack already healthy:

```bash
bash scripts/init-reporting-security.sh
```

Expected result:

```text
PASS: Stage 2 reporting schemas and least-privilege roles initialized.
```

## Apply client configuration

```bash
bash scripts/apply-client-config.sh
```

Expected result:

```text
PASS: Client business configuration applied.
```

## Seed the initial KPI catalogue

```bash
bash scripts/seed-kpi-catalog.sh
```

The initial catalogue contains only the four KPI families already represented in the existing Revenue Intelligence Agent evidence:

- Closed Won Revenue
- Open Pipeline
- Closed Won Deals
- Win Rate

Adding a KPI to the catalogue does **not** by itself authorize arbitrary SQL. Each `query_key` must still map to an approved deterministic query implementation.

## n8n credential boundary

Create two PostgreSQL credentials in the Agent v2 n8n instance:

1. reporting reader — `REPORTING_DB_READER_USER`
2. audit writer — `AUDIT_DB_WRITER_USER`

Use the reporting reader only for governed KPI/report reads.

Use the audit writer only for audit-event inserts.

Do not create normal workflow credentials using the database administrator.

## Stage 2 acceptance criteria

Stage 2 is complete only after local verification confirms:

1. security migration runs without error
2. client business configuration is present
3. four initial KPI definitions are present
4. reporting reader can read reporting/governance data
5. reporting reader cannot write reporting data
6. audit writer can insert audit events
7. audit writer cannot read reporting data
8. administrator credential is absent from ordinary n8n workflow nodes
9. existing Stage 1 health checks continue to pass

## Verified reference-deployment result

The Stage 2 verification script has confirmed:

- client business configuration exists
- four active governed KPI definitions are present
- reporting-reader credentials authenticate successfully
- reporting reader has reporting/governance read access and no governance update access
- audit-writer credentials authenticate successfully
- audit writer can insert audit events
- audit writer cannot read reporting/governance data
- the Stage 1 container health checks remain green
- the fresh Agent v2 n8n instance contains no database credentials yet, so no administrator database credential is embedded in ordinary workflow nodes

## Next stage

**Stage 3 — Connector & Data Contract Layer**

Stage 3 will standardize how HubSpot, Salesforce, billing, spreadsheets, and other business sources map into a canonical reporting model without rewriting the core agent for every client.

# Database

This folder contains sanitized, portfolio-safe database artifacts for the deployable Revenue Intelligence Agent.

## Migrations

- `migrations/001_stage2_security.sql` — business configuration, KPI governance, audit table, and Stage 2 least-privilege roles
- `migrations/002_stage3_connector_contract.sql` — connector mapping metadata, canonical deal contract, controlled ingestion gateway, approved-query registry, and connector-ingestion role
- `migrations/003_semantic_layer.sql` — governed dimensions, filters, date fields, formula metadata, normalized KPI policies, and deterministic semantic resolution
- `migrations/004_identity_permissions.sql` — principals, departments, role assignments, semantic role validation, and deterministic data-scope authorization
- `migrations/005_agent_execution_core.sql` — governed relative periods, identity-aware metric execution, approved runtime filters, and deterministic current/previous-period analysis

## Seeds

- `seeds/001_kpi_catalog.sql` — four governed KPI definitions
- `seeds/002_query_templates.sql` — deterministic templates for the four approved KPI query keys
- `seeds/003_semantic_catalog.sql` — canonical semantic mappings and formula metadata for the existing governed KPIs
- `seeds/004_role_policies.sql` — reusable baseline revenue-admin, revenue-manager, and sales-rep permission policies; no real users or departments

The canonical Stage 3 reporting model is `reporting.deals`.

Never commit database passwords, connection strings containing credentials, production dumps, private client data, or unsanitized source records.

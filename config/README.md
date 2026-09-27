# Client Configuration

Client-specific runtime values belong in the private `deploy/.env` file and the governed PostgreSQL configuration tables.

Do not hard-code client names, timezones, currencies, fiscal calendars, pipeline thresholds, credentials, CRM object IDs, or API tokens into reusable n8n workflow templates.

Stage 2 stores these business-level settings in `governance.business_config`:

- company name
- timezone
- currency
- fiscal-year start month
- stale-deal threshold
- minimum pipeline-coverage threshold

KPI definitions are versioned separately in `governance.kpi_catalog`.

Permissions are represented in `governance.role_policy` and will be connected to external identity/RBAC in a later stage.

# Client Configuration

Client-specific values must stay outside reusable workflow logic.

## Business configuration

Private runtime values belong in `deploy/.env` and governed PostgreSQL configuration tables.

Stage 2 stores business-level settings in `governance.business_config`:

- company name
- timezone
- currency
- fiscal-year start month
- stale-deal threshold
- minimum pipeline-coverage threshold

KPI definitions are versioned in `governance.kpi_catalog`.

Permissions continue to use `governance.role_policy`. The identity/permissions layer now connects those policies to provider-neutral principals, departments, role assignments, and own/department/all-business data scopes. External authentication/SSO remains a later integration.

## Connector configuration

Stage 3 stores non-secret connector metadata in:

- `governance.connector_registry`
- `governance.connector_field_mapping`
- `governance.connector_value_mapping`

Use `config/connectors.example.json` as the public template.

For a real client, create `config/connectors.local.json`. That file is ignored by Git and can be applied with:

```bash
bash scripts/apply-connector-config.sh
```

Connector configuration may contain source field names, canonical field mappings, deterministic transform keys, and stage-value mappings.

Do not place client names, credentials, CRM object secrets, OAuth tokens, API keys, passwords, private keys, or n8n credential payloads into reusable workflow templates or connector configuration files.

Actual connector credentials must remain in the private credential/environment layer.

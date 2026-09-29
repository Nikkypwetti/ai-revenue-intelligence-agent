# Agent V2 Local Control Dashboard

Workflow: `REVINT-V2-CONTROL-01 | Local Control Dashboard`

The Control Dashboard is a local-only, read-only operations surface for the AI Revenue Intelligence Agent V2. It gives an operator one place to inspect the current business configuration, governed KPI count, CRM connector activation, reliability component state, circuit state, recent failures, dead-letter backlog and active observability alerts.

## Why this exists

The project already had governed reporting, connector orchestration, reliability, observability and audit controls, but those controls were distributed across n8n and PostgreSQL. The dashboard turns the existing governed status surfaces into a single operational view without creating another source of truth or a privileged administration path.

## Security boundary

The dashboard intentionally does **not** provide write controls.

- GET-only webhook
- local Agent V2 loopback port only
- no route through the public nginx ingress
- uses the existing `REVINT | Reporting RO` credential
- no access to credentials or secret values
- no arbitrary SQL
- no raw audit payloads
- no connector activation/deactivation action
- no workflow publishing or mutation action
- database values are HTML-escaped before rendering
- no-store response and restrictive CSP/browser headers

This keeps the dashboard useful for operations while preserving the existing rule:

> AI interprets. Deterministic controls authorize. PostgreSQL permissions enforce the final security boundary.

## Dashboard sections

### Runtime summary

Shows:

- overall runtime state
- active governed KPI count
- managed reliability component count
- open dead-letter count

### CRM & source connectors

Reads the governed connector registry and shows each connector as:

- active
- safe-disabled

This makes the HubSpot/Salesforce/Airtable rollout state visible without allowing the browser to change it.

### Reliability & observability

Uses existing bounded observability surfaces to show:

- component status
- circuit state
- recent terminal failures
- open dead letters
- latest successful execution state

### Active alerts

Shows up to the latest 10 rows from `observability.alert_ready`.

## Deploy locally

The workflow is repository-disabled and requires explicit deployment:

```bash
bash scripts/deploy-control-dashboard.sh \
  --confirm REVINT_CONTROL_DASHBOARD
```

Then open:

```text
http://localhost:5681/webhook/revint/v2/control
```

If the local Agent V2 port differs, use the configured `N8N_PORT`.

## Public/client deployment

Do not expose this local route directly. A future public client version should sit behind the existing SSO/OIDC edge and use a separate authenticated route. Write actions, if ever added, should use explicit RBAC, human confirmation, CSRF protection, server-side authorization and dedicated bounded functions rather than direct browser-to-database mutation.

## Portfolio evidence

For portfolio use, capture a screenshot only after local deployment and runtime verification. The screenshot should show the runtime summary, connector states and reliability table without exposing credentials, tokens, email addresses, internal IDs that are not needed for the case study, or client-sensitive data.

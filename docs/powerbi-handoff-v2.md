# Agent V2 — Power BI Local Dataset Handoff

This stage provides a real Power BI-ready handoff without requiring a VPS, public database endpoint, domain, or cloud gateway.

## What it exports

The export package contains:

- `deals.csv` — canonical `reporting.deals`
- `component_status.csv` — bounded operational component status
- `runtime_status.csv` — one-row overall runtime status
- `manifest.env` — source, timestamp, row counts and data-scope metadata
- `SHA256SUMS` — integrity hashes

The export uses the existing **Reporting RO** credential.

It cannot modify:

- CRM sources
- canonical deal facts
- governance tables
- audit/dead-letter data

## Data-scope warning

This is intentionally a **business-wide management extract**.

It is not a substitute for Agent V2's per-principal own/department/all RBAC gateway.

Treat the generated files as trusted management analytics artifacts. If a future client requires user-specific Power BI row-level security, implement and test RLS separately rather than assuming Agent V2 API RBAC automatically transfers into Power BI.

## Create an export

```bash
bash scripts/export-powerbi-dataset.sh \
  --confirm REVINT_POWERBI_EXPORT
```

Default output:

```text
exports/powerbi/<UTC timestamp>/
```

The directory should remain local/private and is intended to be Git-ignored.

## Power BI use

On a machine with Power BI Desktop:

1. Get Data → Text/CSV.
2. Load `deals.csv`.
3. Optionally load `component_status.csv` and `runtime_status.csv`.
4. Build the management dashboard from canonical columns rather than CRM-specific raw fields.
5. Keep the manifest/checksum files with the evidence package.

The same canonical extract can later be uploaded to an approved client analytics location or refreshed through a gateway.

## Future direct refresh

A direct Power BI Service refresh should be implemented only when the client has an approved always-on connectivity path, such as:

- an on-premises data gateway
- a private network/VPN
- a secured cloud database/read replica
- another approved analytics staging layer

Do not publicly expose the Agent V2 PostgreSQL database merely to make Power BI refresh easier.

## Current status

Repository export/handoff implementation: ready.

Live export execution: pending local Desktop runtime access.

No VPS/domain purchase is required to validate the local export path.

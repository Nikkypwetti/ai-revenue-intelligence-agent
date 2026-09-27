# Agent v2 — Identity & Permissions

## Status

This layer extends the existing `governance.role_policy` model rather than replacing it.

It is designed for a single-business deployment and keeps authentication separate from authorization.

## What is added

The governance database now models:

- principals/users
- departments
- department membership
- role assignments
- KPI permissions
- dimension permissions
- filter permissions
- row limits
- own, department, and all-business data scopes

No real client users or departments are seeded.

Only reusable baseline role policies are seeded.

## Baseline role policies

The initial policy templates are:

- `revenue_admin` — all-business scope, maximum 1000 rows
- `revenue_manager` — department scope, maximum 500 rows
- `sales_rep` — own-record scope, maximum 250 rows

All three currently use the four governed KPI definitions from the existing semantic layer.

Clients can change these policies during onboarding without changing workflow code.

## Identity model

`governance.principal_registry` stores an internal `principal_key` plus optional external identity metadata.

The current layer does not authenticate a user.

A trusted gateway or later identity provider integration must authenticate the person first and then pass the mapped internal principal key into the deterministic authorization layer.

Direct identity-table reads are not granted to the reporting runtime credential.

## Department scope

The canonical reporting model does not contain a department column.

Department access is therefore resolved through active principal membership and each principal's canonical `sales_rep` mapping.

For example, a manager in a Sales department receives an approved `sales_rep` scope containing the active sales reps mapped to that same department.

The later query resolver must bind this returned scope to the approved SQL path.

## Deterministic authorization gateway

Use:

```sql
governance.authorize_kpi_request(
  principal_key,
  kpi_key,
  requested_dimensions,
  requested_filters
)
```

The function checks:

- principal existence and active state
- active role assignments
- governed KPI access
- KPI-level dimension/filter permissions
- role-level dimension/filter permissions
- maximum row limit
- own/department/all data scope
- required canonical sales-rep mappings

The result returns `allowed`, a deterministic reason code, the row limit, data-scope mode, and the canonical scope values required for downstream query enforcement.

It never accepts SQL and never generates SQL.

## Least privilege

The existing reporting runtime can execute the bounded authorization function but cannot directly read:

- `governance.principal_registry`
- `governance.department_membership`
- `governance.role_assignment`

This prevents the reporting credential from becoming a general-purpose identity-directory reader.

## Initialize

```bash
bash scripts/init-identity-permissions.sh
```

The command is idempotent and uses the existing private deployment environment.

## Verify

```bash
bash scripts/verify-identity-permissions.sh
```

Verification creates temporary fixture principals and departments, tests own/department/all authorization, checks denial paths and database privileges, removes the fixtures, and then runs the full semantic/runtime/security/health regression chain.

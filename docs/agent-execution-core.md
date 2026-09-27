# Agent v2 — Agent Execution Core

## Status

Locally deployable and verifiable on the isolated Agent v2 runtime.

This milestone reuses the request/governance ideas from the earlier sanitized `REVINT-01` portfolio workflow, but it does **not** import that workflow as a production backup.

## What this layer adds

The Agent execution core provides:

- authenticated local report intake
- a bounded natural-language fallback interpreter for the four existing governed KPIs
- a structured-intent input contract for a future LLM adapter
- safe clarification when metric, date period, or report shape is ambiguous
- deterministic identity/permission authorization
- scope-aware metric execution
- previous-period comparison and trend calculations
- bounded public report and rejection responses
- append-only audit events through the existing audit-writer credential

## Supported KPI keys

The runtime uses the four KPI definitions already in the governed catalogue:

- `closed_won_revenue`
- `open_pipeline`
- `closed_won_deals`
- `win_rate`

No new KPI formula is introduced here.

## Natural-language fallback

There is no LLM credential in the isolated Agent v2 runtime at this stage.

The workflow therefore includes a deliberately small deterministic interpreter for explicit questions such as:

- `What is our open pipeline this month?`
- `What was closed won revenue last month?`
- `What is our win rate this quarter?`
- `Compare closed won revenue this month with the previous period.`

If the metric, period, or requested report shape cannot be resolved safely, the workflow returns `clarification_required` instead of guessing.

Breakdowns such as `pipeline by sales rep` are not executed by this first scalar agent core. The semantic and identity layers already govern those dimensions, but grouped-query execution should be added explicitly rather than generated dynamically.

## Structured intent contract

A trusted future interpreter may submit:

```json
{
  "principal_key": "user-123",
  "structured_intent": {
    "kpi_key": "open_pipeline",
    "period_key": "this_month",
    "mode": "metric_report",
    "filters": {
      "lead_source": ["Referral"]
    }
  }
}
```

Allowed modes are `metric_report`, `trend_report`, and `comparison_report`.

Allowed filter fields are `sales_rep`, `lead_source`, and `deal_stage`.

The database revalidates authorization and filter values before reading reporting data.

## Deterministic execution

`governance.execute_agent_metric_request` resolves the configured timezone, reporting period, principal authorization, approved KPI query key, scope-aware metric result, and optional previous-period analysis.

The function contains no user-supplied SQL and no dynamic SQL.

## Authentication boundary

The local endpoint is:

```text
POST http://127.0.0.1:5681/webhook/revint/v2/report
```

It uses the header `X-Revint-Report-Key`.

This shared local API key protects the endpoint, but it is **not** per-user authentication or SSO. `principal_key` remains an authorization identity supplied to the bounded local gateway.

Public ingress and external identity-provider authentication remain later deployment work.

## Initialize and deploy

```bash
bash scripts/deploy-agent-core.sh
```

## Verify

```bash
bash scripts/verify-agent-core.sh
```

Verification uses temporary principals and canonical deal fixtures, tests natural-language and structured-intent requests, checks safe clarification and authorization denial, validates data scopes, and runs the complete existing regression chain.

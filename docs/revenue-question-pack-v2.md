# Agent V2 Revenue Question Pack

## Purpose

The Revenue Question Pack expands the reusable Agent V2 semantic layer from four headline KPIs to 37 governed KPI contracts across nine metric packs.

The design rule remains unchanged:

> AI interprets. Deterministic controls authorize. PostgreSQL permissions enforce the final security boundary.

The pack does not give the model arbitrary SQL authority. Every supported question must resolve to an approved metric contract, allowed dimension/filter policy, bounded execution path, role/data scope, and required data domain.

## Metric packs

### Pipeline
- open_pipeline
- open_deals_count
- weighted_pipeline
- pipeline_coverage_ratio
- stale_open_deals_count
- stale_pipeline_value

### Revenue
- closed_won_revenue
- closed_won_deals
- win_rate
- average_deal_size
- closed_lost_deals
- loss_rate
- average_acv
- average_discount_percent
### Forecast
- commit_forecast
- best_case_forecast
- forecast_accuracy

### Velocity
- average_sales_cycle_days
- average_stage_age_days
- pipeline_velocity

### Performance
- quota_attainment

### Activity
- speed_to_lead_hours
- follow_up_sla_compliance
- overdue_followups

### Data quality
- crm_data_quality_score
- missing_owner_deals
- missing_close_date_deals

### Funnel
- lead_to_mql_rate
- mql_to_sql_rate
- sql_to_opportunity_rate
- opportunity_to_won_rate

### Retention
- current_mrr
- current_arr
- expansion_mrr
- churned_mrr
- net_revenue_retention
- gross_revenue_retention
## Reusable governed data domains

The pack separates metric availability from metric definition. A KPI may be supported by the Agent but unavailable for a client until its required governed source domain is loaded.

| Domain | Typical source | Example metrics |
|---|---|---|
| deals | CRM opportunities/deals | revenue, pipeline, velocity, data quality |
| targets | quota/target system | quota attainment, pipeline coverage |
| funnel | CRM/marketing lifecycle | lead-to-MQL, MQL-to-SQL, SQL-to-opportunity |
| activities | CRM tasks/calls/emails | speed-to-lead, SLA, overdue follow-ups |
| forecasts | forecast snapshots | forecast accuracy |
| subscriptions | billing/subscription system | MRR, ARR, churn, NRR, GRR |

If a required domain is not ready, the V2 gateway returns a governed `unavailable` response with `DATA_DOMAIN_NOT_READY`. It does not return zero as if zero were a real business result.

## Reporting modes

Agent V2 supports:
- `metric_report`
- `comparison_report`
- `trend_report`
- `breakdown_report`
- `diagnostic_report`

Breakdowns are bounded to one approved dimension at a time.

Current governed dimensions include:
- sales_rep
- deal_stage
- lead_source
- segment
- region
- industry
- campaign
- forecast_category
Open-pipeline diagnostics provide deterministic change/context analysis from governed facts instead of free-form causal speculation.

## Client implementation model

The Agent is reusable. A client implementation configures:
- source adapters and credentials
- canonical mappings
- currency/timezone
- users, roles, departments and data scopes
- which data domains are ready
- source-specific dimensions
- client targets/forecast/subscription feeds
- delivery destinations

The semantic engine, authorization boundary, audit model, reliability controls and execution pattern remain reusable.

## Safety behavior

- Existing four KPI contracts remain backward compatible.
- One-dimension breakdowns are governed.
- RBAC scope applies before calculation.
- Missing probability/target/subscription/etc. data fails closed.
- Connector writers can use bounded ingestion functions but cannot write reporting facts directly.
- Reporting readers cannot read identity tables or mutate governed facts.
- AI cannot generate executable SQL.

## Verification

The isolated Revenue Question Pack verification proves all 37 KPI contracts, calculations across six governed data domains, one-dimension breakdowns, pipeline diagnostics, own-scope RBAC, fail-closed data readiness, backward compatibility, and least-privilege ingestion.

The inherited Agent V2 verification chain also passes after the expansion, including connector/data-contract, semantic layer, identity/RBAC, Agent Core, scheduled intelligence, reliability, observability, backup/recovery, upgrade/rollback, HTTPS ingress, SSO, and HubSpot connector foundation.

# Agent V2 Project Walkthrough

## What this project is

AI Revenue Intelligence & Revenue Systems Agent V2 is a reusable, governed reporting platform for Revenue Operations and Business Systems work.

It lets an authorized manager ask a natural-language revenue question, interprets that question with AI, applies deterministic KPI and permission controls, executes only approved reporting logic, returns a management-ready result, and records the execution for audit, reliability, and observability.

The project is intentionally **not** an unrestricted AI-to-database chatbot.

> AI interprets. Deterministic controls authorize. PostgreSQL permissions enforce the final boundary.

## Business problem

Revenue teams often have CRM data but still struggle to answer management questions consistently because KPI definitions, source-specific fields, permissions, missing data, delivery channels, and failure handling are spread across multiple tools.

Agent V2 addresses that by separating:

- manager intent from execution authority
- CRM-specific source logic from canonical reporting logic
- reporting reads from connector writes and audit writes
- AI-generated narrative from deterministic KPI facts
- active production components from safe-disabled client-specific integrations

## My ownership

I designed and implemented the project end to end:

1. Defined the reporting problem, reusable client model, and governance principles.
2. Built the Agent V2 n8n orchestration and sub-workflows.
3. Designed the PostgreSQL semantic, reporting, identity, reliability, and observability layers.
4. Defined 37 governed KPI contracts across nine Revenue Operations packs.
5. Implemented role, data-scope, identity-binding, and least-privilege controls.
6. Built reusable HubSpot, Salesforce, Airtable, and REST source-adapter patterns.
7. Integrated Groq for bounded intent interpretation and grounded management summaries.
8. Implemented governed Gmail and Slack delivery patterns with server-side destination control.
9. Added retries, circuit breakers, dead letters, audit traceability, and runtime observability.
10. Built the local read-only Revenue Intelligence Control Center.
11. Added guarded deployment scripts, static verification, and GitHub Actions checks.
12. Ran live integration, security, recovery, and regression tests and documented handover procedures.

## How a manager question is processed

Example question:

`What is our open pipeline this month?`

The live request path is:

`Authenticated request → server-bound identity → Groq intent → semantic validation → RBAC/data scope → approved PostgreSQL execution → governed facts → grounded management summary → presentation → API/Gmail delivery → audit/reliability/observability`

The LLM does not choose the caller identity, database credential, SQL, tenant, recipient, or authorization outcome.

## Live evidence

### Governed revenue question

A live authenticated API request returned:

- KPI: `open_pipeline`
- Period: `this_month`
- Value: **$1,200 USD**
- Presentation: governed KPI card

The same governed $1,200 fact was delivered successfully through Gmail. The narrative wording varied slightly between runs while the deterministic KPI result stayed unchanged.

### AI execution

The live `REVINT-V2-AI-01` adapter executed Groq for structured reporting-intent interpretation and grounded management-summary generation.

Invalid or unavailable AI output falls back to deterministic behavior rather than becoming executable authority.

### Security

A request without the report credential returned **HTTP 403 Forbidden**.

A separate authenticated request deliberately supplied a fake revenue-admin principal. The audit record for the same request/correlation ID showed:

`bound_principal = service:report-api`

This proves external JSON cannot choose its own privileged identity.

### CRM source to canonical reporting

The active read-only HubSpot adapter successfully feeds the canonical reporting layer.

Current validated evidence shows:

- 3 HubSpot canonical deal rows
- 1 open
- 0 won
- 2 lost

A later incremental sync completed with zero new/changed records and zero rejected records, demonstrating the no-change path and persisted watermark.

### Reliability and recovery

The Control Center surfaced three historical dead letters caused by an invalid JSON response-body error.

The incidents were investigated, later successful executions confirmed recovery, and the dead letters were marked resolved without deleting the audit trail.

A second observability issue was then identified: Slack delivery was intentionally disabled but its reliability policy was still active, causing overall status to remain unknown. The activation policy was corrected so safe-disabled components do not pollute active runtime health.

Final validated Control Center state:

- **HEALTHY**
- **37 governed KPIs**
- **6 active managed components**
- **0 open dead letters**
- **0 recent failures**
- HubSpot active
- REST ingestion active
- Salesforce safe-disabled
- Airtable safe-disabled

## Why the architecture is reusable

CRM-specific adapters own source credentials, field names, stage values, timestamps, cursors, and normalization.

Validated records enter a source-neutral canonical contract. KPI and authorization logic then operate on that canonical model rather than being rewritten for each CRM.

The preferred deployment model is one isolated Agent V2 deployment per client.

## Current activation state

### Live and validated

- Agent Core
- Groq intent and summary adapter
- 37-KPI semantic governance
- authenticated report API
- HubSpot read-only deal sync
- authenticated REST ingestion
- governed Gmail report delivery
- reliability core
- observability core
- local Control Center

### Implemented but intentionally safe-disabled

- Salesforce Opportunity adapter — pending dedicated least-privilege integration-user activation and UAT
- Airtable Opportunity adapter — pending source quota/schema verification
- Slack manager-report delivery — pending client destination configuration
- incident Slack notifications — pending dedicated incident destination

### Deferred until a real external deployment

- public domain and trusted TLS
- real OIDC/SSO identity provider
- always-on VPS/cloud hosting

These are intentionally separated from the validated core rather than being presented as complete before their environment-specific controls are ready.

## 30-second walkthrough

> I designed and built a production-style Revenue Intelligence and Revenue Systems platform that lets an authorized manager ask a natural-language revenue question and receive a governed answer from CRM data. Groq interprets intent and summarizes approved facts, but KPI definitions, permissions, and database execution remain deterministic. I built reusable CRM adapters, least-privilege PostgreSQL controls, governed Gmail delivery, reliability and observability, and a live Control Center. I validated it with HubSpot data, real API requests, security rejection tests, identity-binding tests, incident recovery, and end-to-end report delivery.

## What this demonstrates

The project is evidence of practical capability across Revenue Operations, Revenue Systems, CRM Operations, Business Systems, Sales/GTM Operations, reporting, workflow automation, AI governance, and operational handover.

# Agent V2 — Governed Intelligence & Presentation Migration

## Purpose

This milestone migrates the useful AI and presentation concepts from the earlier sanitized `REVINT-01` portfolio workflow into the secured Agent V2 architecture.

It does **not** restore the old 118-node workflow as a second production reporting engine.

The V2 security gateway, Revenue Question Pack, RBAC, deterministic PostgreSQL execution, reliability, audit, and observability layers remain authoritative.

## Migrated capabilities

- optional Groq structured-intent interpretation
- deterministic fallback when AI is disabled or unavailable
- optional grounded management-summary generation
- KPI-card / table / chart presentation artifact generation
- AI provider configuration separated from client business data
- dedicated encrypted Agent V2 Groq credential

## Request path

```text
authenticated caller
  -> security gateway / server-bound principal
  -> optional internal Groq intent adapter
  -> deterministic intent revalidation
  -> 37-KPI semantic/RBAC gateway
  -> governed PostgreSQL result
  -> optional Groq management summary
  -> deterministic presentation artifact
  -> API response + audit
```

The AI adapter has no public webhook.

## AI authority boundary

Groq may interpret a manager question into the existing V2 structured-intent contract and summarize already-governed business facts.

Groq may **not**:

- generate executable SQL
- select arbitrary tables
- authorize KPIs, dimensions, filters, users, tenants, or scopes
- read database credentials
- change KPI formulas
- modify canonical business facts

## Fail-soft behavior

The Agent Core Execute Sub-workflow nodes use n8n continue-on-error behavior.

If the AI provider fails:

- intent interpretation falls back to the deterministic V2 interpreter
- management-summary generation is omitted
- the governed KPI result remains available
- the AI sub-workflow failure still routes to the Agent V2 reliability/error workflow

## Configuration

Safe defaults:

```text
GROQ_INTENT_ENABLED=false
GROQ_SUMMARY_ENABLED=false
GROQ_INTENT_MODEL=openai/gpt-oss-20b
GROQ_SUMMARY_MODEL=openai/gpt-oss-20b
```

The API key is stored only as the encrypted n8n credential `REVINT | Groq Intelligence`.

Do not copy the Business OS Groq credential into Agent V2.

## Deployment

```bash
bash scripts/init-ai-intelligence-adapter.sh
bash scripts/deploy-ai-intelligence-adapter.sh --confirm REVINT_AI_INTELLIGENCE
```

When either AI feature is enabled, configure `GROQ_API_KEY` privately first.

## Verification

```bash
bash scripts/verify-ai-intelligence-adapter.sh
```

The verifier checks policy least privilege, internal-only AI workflow structure, dedicated credential references, fail-soft Agent Core wiring, presentation generation, live workflow publication, and existing Agent Core regression behavior.

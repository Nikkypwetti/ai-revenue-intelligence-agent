# Agent V2 — Reusable Groq Intelligence Adapter

## Purpose

This adapter migrates the useful AI intent-parsing pattern from the earlier `REVINT-01` portfolio workflow into the secured Agent V2 architecture.

It is optional and safe-disabled by default.

## Request path

```text
Authenticated service / SSO principal
        |
        v
VAL | Use LLM Intent?
        | enabled
        v
AI | Prepare Groq Intent Request
        |
        v
AI | Groq Interpret Intent
        |
        v
VAL | Normalize Groq Intent
        |
        v
CTX | Interpret Report Request
        |
        v
deterministic validation + RBAC + 37-KPI semantic gateway
```

## Security boundary

Groq may interpret only the KPI, reporting period, report mode, one approved dimension, and approved filter values stated in the question.

Groq cannot:

- generate executable SQL
- choose database tables
- authorize a principal
- change tenant identity
- change RBAC/data scope
- create a new KPI
- bypass required data domains
- access database credentials
- execute a governed report

Every model-produced intent is schema-checked and then passes through the same deterministic Agent V2 validator and PostgreSQL authorization gateway.

## Availability behavior

- `REVINT_LLM_ENABLED=false` → deterministic interpreter.
- trusted `structured_intent` supplied → LLM bypassed.
- valid Groq structured intent → deterministic V2 validation/authorization.
- invalid or malformed Groq output → deterministic interpreter fallback.

## Configuration

```text
REVINT_LLM_ENABLED=false
REVINT_LLM_PROVIDER=groq
REVINT_LLM_BASE_URL=https://api.groq.com/openai/v1
REVINT_LLM_MODEL=openai/gpt-oss-20b
REVINT_LLM_TIMEOUT_MS=15000
GROQ_API_KEY=<private>
```

`GROQ_API_KEY` is imported as the encrypted n8n credential `REVINT | Groq AI`. It is not stored in workflow JSON and is not injected into the long-running n8n service environment.

## Migration note

The earlier workflow used Groq both for intent parsing and management summaries. This milestone migrates the **intent interpretation** part first. Management-summary generation, presentation routing, Slack/Form delivery, and Power BI handoff remain separate migration steps so they can be added without weakening the deterministic execution boundary.

# 3–5 Minute Demo Script

Hi, I’m Ganiyu Basirat, and this project is my **AI Revenue Intelligence and Reporting Agent**.

I built it to solve a common operations problem: managers often need quick answers about revenue, pipeline, deals, and performance, but giving an AI unrestricted access to a production database creates security and governance risks.

My solution separates **AI interpretation** from **query authorization**.

The AI helps understand what the manager is asking, but deterministic controls decide what is allowed to run, and PostgreSQL permissions provide the final security boundary.

A manager can submit a request through Slack, a form, or an API. n8n normalizes and validates the request, then sends it to the AI intent parser.

The AI does not generate or execute arbitrary SQL. Instead, it returns structured intent such as the requested metric, filters, and date range.

That intent is checked against a governed KPI catalogue. If approved, the system resolves it to an approved SQL template and executes the query using a PostgreSQL read-only reporting credential.

A successful request for closed-won revenue this month returns **20,500 in closed-won revenue across 2 deals**.

Unsupported or unauthorized reporting requests are rejected before database execution.

At the database level, the reporting credential has SELECT-only access to approved reporting tables and cannot write to reporting data or access the control and audit schemas.

Reports can be delivered through Slack, a web form, and API responses.

The Power BI dashboard tracks **20,500 closed-won revenue this month, 55,000 in current-quarter open pipeline, 2 closed-won deals, and a 60 percent current-quarter win rate**. It also shows pipeline by sales rep, deals by stage, revenue by lead source, and open opportunities.

Every request receives a request ID and correlation ID, and the audit trail records key stages such as request received, intent parsed, governance approved, and delivery succeeded.

I also built a centralized error-handling workflow. Errors are normalized, assigned an incident ID, classified, logged, and routed through either recovery or escalation, with alerting, dead-letter handling, and final audit records.

Overall, this project combines **Revenue Operations, Business Systems, reporting, PostgreSQL security, n8n, AI integration, and Power BI** into one operational system.

The main design principle is simple: **AI interprets the request, deterministic controls authorize execution, and PostgreSQL enforces the final security boundary.**

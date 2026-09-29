# Governed Gmail Report Delivery

Workflow: `REVINT-V2-EMAIL-01 | Governed Email Report Delivery`

This is an internal-only email delivery subworkflow. It receives an already-governed report artifact, authorizes delivery by tenant/principal role, resolves one trusted recipient from PostgreSQL governance, builds bounded escaped HTML, sends through Gmail, and records bounded audit metadata.

## Credential

Dedicated n8n credential:

- Name: `REVINT | Gmail Reports`
- Type: `gmailOAuth2`
- Required Gmail scope: `https://www.googleapis.com/auth/gmail.send`

The deployment script resolves the runtime-generated n8n credential ID by exact credential name; the repository workflow ID is a template reference only.

Do not reuse a Business OS Gmail credential automatically.

## Security boundary

- Repository defaults are disabled.
- Recipient email is stored server-side in `governance.email_destination_registry`.
- Caller/AI input cannot provide or override the recipient.
- Delivery is role-gated through `governance.resolve_email_delivery_request(...)`.
- The Gmail adapter receives governed report/presentation facts only.
- Subject/body are escaped and bounded before send.
- Audit metadata excludes OAuth tokens and message body.
- `email_delivery` has its own reliability/circuit policy.

## Agent Core integration

Agent Core accepts `delivery_channel=email` and routes only successful reports to `REVINT-V2-EMAIL-01`.

Example:

```json
{"question":"What is our open pipeline this month?","delivery_channel":"email"}
```

API remains the default channel. Slack and email are separate governed provider paths.

## Validation status

End-to-end local validation completed on 2026-09-29 through the real Agent Core route:

- request: `delivery_channel=email`
- governed KPI: `open_pipeline`
- governed value: `1200 USD`
- presentation: `kpi_card`
- authorized principal: `service:report-api`
- trusted recipient resolved server-side
- Gmail OAuth send succeeded
- provider message ID returned
- bounded result returned with `status=delivered`, `provider=gmail`, `destination_key=manager_email`
- matching `report_completed` and `email_report_delivered` audit events shared the same request/correlation IDs
- `agent_reporting` circuit: `closed`, zero consecutive failures
- `email_delivery` circuit: `closed`, zero consecutive failures

Canonical runtime workflow ID: `REVINTV2EMAIL01`.

The temporary manual regression caller may remain inactive for future delivery checks. Duplicate cleanup is complete: manually imported workflow `5TeNU49BYFMaHh2l` is archived, while canonical `REVINTV2EMAIL01` remains active, published, and unarchived.

# Agent V2 — Governed Report Delivery

## Purpose

Agent V2 supports governed external report delivery without allowing the caller or AI to choose destinations.

Supported request channels are:

- `api` — default; return the governed report only
- `slack` — route to the internal Slack delivery adapter
- `email` — route to the internal Gmail delivery adapter

Both external provider paths receive only an already-authorized Agent V2 report artifact.

## Architecture

```text
authenticated manager/service
  -> Agent V2 security gateway
  -> AI intent + deterministic semantic/RBAC execution
  -> governed report + presentation artifact
  -> provider-neutral delivery request
       -> Slack requested? -> REVINT-V2-DELIVERY-01
       -> Email requested? -> REVINT-V2-EMAIL-01
       -> otherwise API only
  -> bounded provider result
  -> Agent Core audit
  -> API response
```

## Security boundary

- API remains the default channel.
- Slack and email delivery are independently governed and fail closed.
- Caller input can select only `api`, `slack`, or `email`.
- Caller/AI input cannot provide a Slack channel ID or recipient email address.
- Slack destinations and Gmail recipients are resolved server-side from tenant governance.
- Delivery requires an active principal and an allowed role.
- The default report-delivery policy allows revenue admins/managers and denies sales reps.
- Slack and Gmail use dedicated Agent V2 credentials stored encrypted in n8n.
- Slack reliability/observability becomes active only when Slack report delivery is enabled; a safe-disabled provider is not counted as an unknown runtime component.
- Raw provider responses, OAuth tokens, message bodies, and trusted destinations are not written to report audit events.
- Delivery failure cannot change the governed KPI result.

## Runtime workflows

- `REVINT-V2-AGENT-01 | Governed Report Agent Core` performs provider-neutral routing after presentation generation.
- `REVINT-V2-DELIVERY-01 | Governed Report Delivery` is the internal Slack provider boundary.
- `REVINT-V2-EMAIL-01 | Governed Email Report Delivery` is the internal Gmail provider boundary.

Neither provider adapter exposes a public webhook.

## Request contract

API/SSO callers may request Slack:

```json
{"question":"What is open pipeline this quarter?","delivery_channel":"slack"}
```

or email:

```json
{"question":"What is open pipeline this quarter?","delivery_channel":"email"}
```

The caller selects only the delivery channel. The trusted destination is resolved server-side.

## Slack configuration

Initialize and configure the Slack adapter using the existing delivery scripts:

```bash
bash scripts/init-delivery-adapter.sh

bash scripts/configure-slack-report-delivery.sh \
  --destination-key revenue-reports \
  --channel-id YOUR_SLACK_CHANNEL_ID \
  --display-name "Revenue Reports" \
  --enable

bash scripts/deploy-delivery-adapter.sh --confirm REVINT_DELIVERY_ADAPTER
```

## Gmail configuration

The Gmail provider uses:

- workflow: `REVINT-V2-EMAIL-01`
- credential name: `REVINT | Gmail Reports`
- credential type: `gmailOAuth2`
- minimal Gmail scope: `https://www.googleapis.com/auth/gmail.send`

The trusted recipient is stored in PostgreSQL governance. See `docs/email-delivery.md`.

## Verification

Run:

```bash
bash scripts/verify-delivery-adapter.sh
```

The verifier checks the Slack governance boundary and the Agent Core provider routing, including the email route.

The Gmail adapter also has its own static/runtime validation path. On 2026-09-29, a real Agent Core request using `delivery_channel=email` completed end to end: governed open pipeline was calculated as `1200 USD`, a KPI-card presentation was built, Gmail returned a provider message ID, matching `report_completed` and `email_report_delivered` audit records shared the same request/correlation IDs, and both `agent_reporting` and `email_delivery` circuits finished closed with zero consecutive failures.

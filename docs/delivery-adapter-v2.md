# Agent V2 — Governed Delivery Adapter

## Purpose

This milestone migrates the useful Slack report-delivery concept from the earlier 118-node `REVINT-01` workflow into Agent V2 without restoring duplicated V1 reporting logic.

The delivery adapter receives only an already-authorized Agent V2 report artifact.

## Architecture

```text
authenticated manager/service
  -> Agent V2 security gateway
  -> AI intent + deterministic semantic/RBAC execution
  -> governed report + presentation artifact
  -> delivery request gate
  -> tenant/role/destination authorization
  -> Slack adapter
  -> bounded delivery result + audit
```

API remains the default response channel.
## Security boundary

- Slack delivery is disabled by default.
- Manager text and AI output cannot choose the Slack destination.
- Trusted channel IDs live in the tenant-scoped governance registry.
- Delivery requires an active principal and a delivery-enabled role.
- The default policy allows revenue admins/managers and denies sales reps.
- The Slack credential is dedicated to Agent V2 and stored encrypted in n8n.
- Raw Slack responses, tokens and full report payloads are not written to audit.
- Delivery failure cannot change the governed KPI result.

## Runtime workflows

`REVINT-V2-AGENT-01` adds four delivery orchestration nodes after presentation generation.

`REVINT-V2-DELIVERY-01` contains the external provider boundary and has no public webhook.

## Client configuration

Initialize:

```bash
bash scripts/init-delivery-adapter.sh
```
Configure a trusted destination:

```bash
bash scripts/configure-slack-report-delivery.sh \
  --destination-key revenue-reports \
  --channel-id YOUR_SLACK_CHANNEL_ID \
  --display-name "Revenue Reports" \
  --enable
```

Configure `SLACK_REPORT_ACCESS_TOKEN` privately and set `SLACK_REPORT_ENABLED=true` only when a real client Slack app/channel is ready.

Deploy:

```bash
bash scripts/deploy-delivery-adapter.sh --confirm REVINT_DELIVERY_ADAPTER
```

## Request contract

API/SSO callers may request:

```json
{"question":"What is open pipeline this quarter?","delivery_channel":"slack"}
```

The caller selects only the delivery channel. The caller cannot supply the destination.
## What remains from the old workflow

The following V1 concepts are now migrated:

- Groq intent interpretation
- grounded management summary
- KPI/table/chart presentation artifact
- governed Slack report delivery

The old `REVINT-06` n8n Form is not being exposed directly as a public production form. For a real client, manager web/form access should sit behind the same OIDC/SSO security boundary.

Power BI remains a downstream reporting consumer of the governed warehouse/semantic model rather than a security authority inside Agent Core.

External incident notification is still separate from report delivery and should use its own incident destination/policy.

## Verification

Run:

```bash
bash scripts/verify-delivery-adapter.sh
```

The verifier checks default-disabled behavior, tenant/role/destination authorization, least privilege, internal-only workflow structure and Agent Core wiring.

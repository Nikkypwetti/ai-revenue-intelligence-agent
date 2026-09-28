#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
ENDPOINT="http://127.0.0.1:${N8N_PORT:-5681}/webhook/revint/v2/report"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  REPORTING_DB_ADMIN_USER REPORTING_DB_NAME
  REPORTING_DB_READER_USER REPORTING_DB_READER_PASSWORD
  N8N_DB_USER N8N_DB_NAME REPORT_API_KEY CLIENT_CURRENCY
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

psql_admin() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" "$@"
}

psql_n8n() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$N8N_DB_USER" -d "$N8N_DB_NAME" "$@"
}

cleanup() {
  psql_admin -c "
    DELETE FROM audit.agent_events
    WHERE stage='agent_core'
      AND actor='n8n_agent_core'
      AND payload->>'principal_key' LIKE 'verify-agent-%';

    DELETE FROM reporting.deals
    WHERE source_record_id LIKE 'agent-core-verify-%';

    DELETE FROM governance.role_assignment
    WHERE principal_key LIKE 'verify-agent-%';

    DELETE FROM governance.department_membership
    WHERE principal_key LIKE 'verify-agent-%';

    DELETE FROM governance.principal_registry
    WHERE principal_key LIKE 'verify-agent-%';

    DELETE FROM governance.department_catalog
    WHERE department_key='verify-agent-sales';
  " >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

workflow_state="$(psql_n8n -c "
  SELECT active::int || '|' ||
         (\"versionId\" = \"activeVersionId\")::int
  FROM workflow_entity
  WHERE id='REVINTV2AGENTCORE01';
")"
[[ "$workflow_state" == "1|1" ]] || {
  echo "FAIL: Agent core workflow is not active on its current version."
  exit 1
}

webhook_count="$(psql_n8n -c "
  SELECT count(*)
  FROM webhook_entity
  WHERE \"workflowId\"='REVINTV2AGENTCORE01'
    AND \"webhookPath\"='revint/v2/report'
    AND method='POST';
")"
[[ "$webhook_count" == "1" ]] || {
  echo "FAIL: Agent report webhook is not registered exactly once."
  exit 1
}

credential_state="$(psql_n8n -c "
  SELECT count(*) || '|' ||
         count(*) FILTER (WHERE data NOT LIKE '{%')
  FROM credentials_entity
  WHERE id='REVINTREPORTHEADER001';
")"
[[ "$credential_state" == "1|1" ]] || {
  echo "FAIL: Agent report header credential is missing or not encrypted."
  exit 1
}

bash "$ROOT_DIR/scripts/verify-runtime-isolation.sh"

psql_admin <<'SQL' >/dev/null
INSERT INTO governance.department_catalog (
  department_key, display_name, active
)
VALUES ('verify-agent-sales','Agent Core Verification Sales',true);

INSERT INTO governance.principal_registry (
  principal_key, display_name, identity_provider,
  external_subject, canonical_sales_rep, active
)
VALUES
  ('verify-agent-rep-a','Verify Agent Rep A','test','agent-rep-a','Verify Agent Rep A',true),
  ('verify-agent-rep-b','Verify Agent Rep B','test','agent-rep-b','Verify Agent Rep B',true),
  ('verify-agent-manager','Verify Agent Manager','test','agent-manager',NULL,true),
  ('verify-agent-admin','Verify Agent Admin','test','agent-admin',NULL,true),
  ('verify-agent-unmapped','Verify Agent Unmapped','test','agent-unmapped',NULL,true);

INSERT INTO governance.department_membership (
  principal_key, department_key, is_primary
)
VALUES
  ('verify-agent-rep-a','verify-agent-sales',true),
  ('verify-agent-rep-b','verify-agent-sales',true),
  ('verify-agent-manager','verify-agent-sales',true),
  ('verify-agent-unmapped','verify-agent-sales',true);

INSERT INTO governance.role_assignment (principal_key, role_key)
VALUES
  ('verify-agent-rep-a','sales_rep'),
  ('verify-agent-rep-b','sales_rep'),
  ('verify-agent-manager','revenue_manager'),
  ('verify-agent-admin','revenue_admin'),
  ('verify-agent-unmapped','sales_rep');

WITH p AS (
  SELECT *
  FROM governance.resolve_relative_period('this_month', now())
),
cfg AS (
  SELECT trim(both FROM currency_code::text) AS currency_code
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1
)
INSERT INTO reporting.deals (
  connector_key, source_record_id, deal_name, amount, currency_code,
  stage_name, stage_category, sales_rep, lead_source,
  created_at, expected_close_date, closed_at, source_updated_at,
  source_payload_hash, contract_version, ingested_at
)
SELECT * FROM (
  SELECT
    'rest_ingestion_api'::text, 'agent-core-verify-open-a-current'::text,
    'Agent Core Open A Current'::text, 1000::numeric, cfg.currency_code::char(3),
    'Prospecting'::text, 'open'::text, 'Verify Agent Rep A'::text, 'VerifyReferral'::text,
    p.start_at, p.start_at + interval '3 days', NULL::timestamptz, p.start_at,
    md5('agent-core-verify-open-a-current'), 1, now()
  FROM p,cfg
  UNION ALL
  SELECT
    'rest_ingestion_api', 'agent-core-verify-open-b-current',
    'Agent Core Open B Current', 2000, cfg.currency_code::char(3),
    'Prospecting', 'open', 'Verify Agent Rep B', 'VerifyDirect',
    p.start_at, p.start_at + interval '4 days', NULL::timestamptz, p.start_at,
    md5('agent-core-verify-open-b-current'), 1, now()
  FROM p,cfg
  UNION ALL
  SELECT
    'rest_ingestion_api', 'agent-core-verify-open-a-previous',
    'Agent Core Open A Previous', 500, cfg.currency_code::char(3),
    'Prospecting', 'open', 'Verify Agent Rep A', 'VerifyReferral',
    p.previous_start_at, p.previous_start_at + interval '3 days', NULL::timestamptz, p.previous_start_at,
    md5('agent-core-verify-open-a-previous'), 1, now()
  FROM p,cfg
  UNION ALL
  SELECT
    'rest_ingestion_api', 'agent-core-verify-open-b-previous',
    'Agent Core Open B Previous', 1000, cfg.currency_code::char(3),
    'Prospecting', 'open', 'Verify Agent Rep B', 'VerifyDirect',
    p.previous_start_at, p.previous_start_at + interval '4 days', NULL::timestamptz, p.previous_start_at,
    md5('agent-core-verify-open-b-previous'), 1, now()
  FROM p,cfg
  UNION ALL
  SELECT
    'rest_ingestion_api', 'agent-core-verify-won-current',
    'Agent Core Won Current', 1500, cfg.currency_code::char(3),
    'Closed Won', 'won', 'Verify Agent Rep A', 'VerifyReferral',
    p.start_at, p.start_at + interval '2 days', p.start_at + interval '2 days', p.start_at,
    md5('agent-core-verify-won-current'), 1, now()
  FROM p,cfg
  UNION ALL
  SELECT
    'rest_ingestion_api', 'agent-core-verify-lost-current',
    'Agent Core Lost Current', 900, cfg.currency_code::char(3),
    'Closed Lost', 'lost', 'Verify Agent Rep A', 'VerifyReferral',
    p.start_at, p.start_at + interval '2 days', p.start_at + interval '2 days', p.start_at,
    md5('agent-core-verify-lost-current'), 1, now()
  FROM p,cfg
  UNION ALL
  SELECT
    'rest_ingestion_api', 'agent-core-verify-won-previous',
    'Agent Core Won Previous', 700, cfg.currency_code::char(3),
    'Closed Won', 'won', 'Verify Agent Rep A', 'VerifyReferral',
    p.previous_start_at, p.previous_start_at + interval '2 days',
    p.previous_start_at + interval '2 days', p.previous_start_at,
    md5('agent-core-verify-won-previous'), 1, now()
  FROM p,cfg
) AS fixtures(
  connector_key, source_record_id, deal_name, amount, currency_code,
  stage_name, stage_category, sales_rep, lead_source,
  created_at, expected_close_date, closed_at, source_updated_at,
  source_payload_hash, contract_version, ingested_at
)
ON CONFLICT (connector_key, source_record_id) DO UPDATE SET
  amount=EXCLUDED.amount,
  sales_rep=EXCLUDED.sales_rep,
  lead_source=EXCLUDED.lead_source,
  expected_close_date=EXCLUDED.expected_close_date,
  closed_at=EXCLUDED.closed_at,
  source_payload_hash=EXCLUDED.source_payload_hash,
  ingested_at=now();
SQL

python3 - <<'PY'
import json
import os
import urllib.error
import urllib.request

url = f"http://127.0.0.1:{os.environ.get('N8N_PORT', '5681')}/webhook/revint/v2/report"
key = os.environ["REPORT_API_KEY"]

def post(payload, authenticated=True):
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if authenticated:
        headers["X-Revint-Report-Key"] = key
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            return res.status, json.loads(res.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = {"raw": body}
        return exc.code, parsed

status, _ = post(
    {"principal_key":"verify-agent-rep-a","question":"What is our open pipeline this month?"},
    authenticated=False,
)
if status != 403:
    raise SystemExit(f"FAIL: unauthenticated report request returned {status}, expected 403")

status, body = post({
    "principal_key":"verify-agent-rep-a",
    "question":"What is our open pipeline this month?"
})
value = body.get("report",{}).get("current_period",{}).get("value")
if status != 200 or body.get("status") != "success" or float(value) != 1000.0:
    raise SystemExit(f"FAIL: own-scope open pipeline response was {status} {body}")

status, body = post({
    "principal_key":"verify-agent-manager",
    "question":"Compare open pipeline this month with previous period."
})
report = body.get("report",{})
current = report.get("current_period",{}).get("value")
previous = report.get("previous_period",{}).get("value")
analysis = report.get("analysis",{})
if (
    status != 200 or
    float(current) != 3000.0 or
    float(previous) != 1500.0 or
    float(analysis.get("delta")) != 1500.0 or
    float(analysis.get("percent_change")) != 100.0 or
    analysis.get("direction") != "up"
):
    raise SystemExit(f"FAIL: department comparison response was {status} {body}")

status, body = post({
    "principal_key":"verify-agent-admin",
    "structured_intent":{
        "kpi_key":"open_pipeline",
        "period_key":"this_month",
        "mode":"metric_report",
        "filters":{"lead_source":["VerifyReferral"]}
    }
})
value = body.get("report",{}).get("current_period",{}).get("value")
if status != 200 or float(value) != 1000.0:
    raise SystemExit(f"FAIL: structured filtered admin response was {status} {body}")

status, body = post({
    "principal_key":"verify-agent-manager",
    "question":"How is pipeline by sales rep this month?"
})
report = body.get("report",{})
rows = report.get("current_period",{}).get("rows") or []
row_map = {row.get("dimension_value"): float(row.get("value")) for row in rows}
if (
    status != 200 or body.get("status") != "success" or
    report.get("report_type") != "breakdown" or
    report.get("dimensions") != ["sales_rep"] or
    row_map.get("Verify Agent Rep A") != 1000.0 or
    row_map.get("Verify Agent Rep B") != 2000.0
):
    raise SystemExit(f"FAIL: sales-rep pipeline breakdown was {status} {body}")

status, body = post({
    "principal_key":"verify-agent-rep-a",
    "question":"What is our win rate?"
})
codes = [q.get("code") for q in body.get("questions",[])]
if status != 422 or "PERIOD_CLARIFICATION_REQUIRED" not in codes:
    raise SystemExit(f"FAIL: missing-period clarification response was {status} {body}")

status, body = post({
    "principal_key":"verify-agent-unmapped",
    "question":"What is our open pipeline this month?"
})
if status != 403 or body.get("status") != "rejected":
    raise SystemExit(f"FAIL: unmapped own-scope principal response was {status} {body}")

print("PASS: authenticated natural-language KPI request respects own data scope.")
print("PASS: comparison request returns deterministic current/previous analysis.")
print("PASS: structured intent applies an approved governed filter.")
print("PASS: governed one-dimension breakdown executes and missing-period requests still clarify.")
print("PASS: unauthorized own-scope identity is rejected.")
print("PASS: unauthenticated report requests are rejected before workflow execution.")
PY

audit_count="$(psql_admin -c "
  SELECT count(*)
  FROM audit.agent_events
  WHERE stage='agent_core'
    AND actor='n8n_agent_core'
    AND payload->>'principal_key' LIKE 'verify-agent-%';
")"
[[ "$audit_count" -ge 6 ]] || {
  echo "FAIL: expected at least six Agent core audit events."
  exit 1
}

permission_state="$(psql_admin -c "
  SELECT
    has_function_privilege(
      '$REPORTING_DB_READER_USER',
      'governance.execute_agent_metric_request(text,text,text,text,jsonb,timestamptz)',
      'EXECUTE'
    )::int || '|' ||
    has_function_privilege(
      '$REPORTING_DB_READER_USER',
      'governance.execute_agent_report_request_v2(text,text,text,text,jsonb,jsonb,timestamptz)',
      'EXECUTE'
    )::int || '|' ||
    has_table_privilege(
      '$REPORTING_DB_READER_USER',
      'governance.principal_registry',
      'SELECT'
    )::int;
")"
[[ "$permission_state" == "1|1|0" ]] || {
  echo "FAIL: reporting-reader Agent core privilege boundary is incorrect."
  exit 1
}

echo "PASS: Agent core events are audited."
echo "PASS: reporting reader can execute the bounded Agent gateway but cannot read identity tables."

bash "$ROOT_DIR/scripts/verify-identity-permissions.sh"

echo "PASS: Agent v2 governed execution-core verification passed."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
RELIABILITY_SEED="$ROOT_DIR/database/seeds/011_delivery_reliability.sql"
DEPLOY_SCRIPT="$ROOT_DIR/scripts/deploy-delivery-adapter.sh"
CONFIGURE_SCRIPT="$ROOT_DIR/scripts/configure-slack-report-delivery.sh"

set -a
source "$ENV_FILE"
set +a

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
TEST_DB="revint_delivery_verify_$$"
cleanup() {
  "${compose[@]}" exec -T reporting-db dropdb --if-exists     -U "$REPORTING_DB_ADMIN_USER" "$TEST_DB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${compose[@]}" exec -T reporting-db createdb -U "$REPORTING_DB_ADMIN_USER" "$TEST_DB"
"${compose[@]}" exec -T reporting-db pg_dump -U "$REPORTING_DB_ADMIN_USER"   -d "$REPORTING_DB_NAME" --no-owner |
  "${compose[@]}" exec -T reporting-db psql -X -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$TEST_DB" >/dev/null

SECURITY_GATEWAY_DB_NAME="$TEST_DB" bash "$ROOT_DIR/scripts/init-security-gateway.sh" >/dev/null
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$TEST_DB"   -f /dev/stdin < "$ROOT_DIR/database/migrations/016_delivery_adapter.sql" >/dev/null

psql_admin() {
  "${compose[@]}" exec -T reporting-db psql -X -q -A -t -v ON_ERROR_STOP=1     -U "$REPORTING_DB_ADMIN_USER" -d "$TEST_DB" "$@"
}

disabled="$(psql_admin -c "
SELECT allowed::int || '|' || reason
FROM governance.resolve_delivery_request('service:report-api','slack_report');
")"
[[ "$disabled" == "0|DELIVERY_DISABLED" ]] || {
  echo "FAIL: delivery did not default fail-closed: $disabled"; exit 1;
}

psql_admin <<'SQL' >/dev/null
INSERT INTO governance.delivery_destination_registry(
  destination_key,tenant_key,provider_key,purpose_key,
  external_destination_id,display_name,active
) VALUES ('verify-reports','default','slack','manager_report','CVERIFY123','Verify reports',true);

UPDATE governance.delivery_adapter_config
SET slack_report_enabled=true,updated_at=now()
WHERE config_id=1;
SQL
authorized="$(psql_admin -c "
SELECT allowed::int || '|' || reason || '|' || external_destination_id
FROM governance.resolve_delivery_request('service:report-api','slack_report');
")"
[[ "$authorized" == "1|AUTHORIZED|CVERIFY123" ]] || {
  echo "FAIL: configured report service was not authorized: $authorized"; exit 1;
}

psql_admin <<'SQL' >/dev/null
INSERT INTO governance.principal_registry(
  principal_key,display_name,identity_provider,active,tenant_key
) VALUES ('verify-sales-rep','Verify sales rep','test',true,'default')
ON CONFLICT (principal_key) DO UPDATE SET active=true,tenant_key='default';

INSERT INTO governance.role_assignment(principal_key,role_key,active)
VALUES ('verify-sales-rep','sales_rep',true)
ON CONFLICT (principal_key,role_key) DO UPDATE SET active=true;
SQL

rep_state="$(psql_admin -c "
SELECT allowed::int || '|' || reason
FROM governance.resolve_delivery_request('verify-sales-rep','slack_report');
")"
[[ "$rep_state" == "0|DELIVERY_ROLE_NOT_ALLOWED" ]] || {
  echo "FAIL: sales-rep delivery policy did not fail closed: $rep_state"; exit 1;
}
privs="$(psql_admin -c "
SELECT
  has_function_privilege('$REPORTING_DB_READER_USER',
    'governance.resolve_delivery_request(text,text)','EXECUTE')::int || '|' ||
  has_table_privilege('$REPORTING_DB_READER_USER',
    'governance.delivery_destination_registry','SELECT')::int;
")"
[[ "$privs" == "1|0" ]] || {
  echo "FAIL: delivery least-privilege boundary incorrect: $privs"; exit 1;
}

cd "$ROOT_DIR"
python3 - <<'PY'
import json
d=json.load(open('workflows/runtime-templates/REVINT-V2-DELIVERY-01.json'))
w=d[0] if isinstance(d,list) else d
names={n['name'] for n in w['nodes']}
required={'DB | Resolve Delivery Authorization','DEL | Send Slack Report','AUD | Log Slack Delivery'}
assert required <= names
assert not any(n['type']=='n8n-nodes-base.webhook' for n in w['nodes'])
send=next(n for n in w['nodes'] if n['name']=='DEL | Send Slack Report')
assert send['credentials']['slackApi']['id']=='REVINTSLACKREPORT001'
agent=json.load(open('workflows/runtime-templates/REVINT-V2-AGENT-01.json'))
agent=agent[0] if isinstance(agent,list) else agent
an={n['name'] for n in agent['nodes']}
assert {'CTX | Prepare Delivery Request','VAL | Slack Delivery Requested?','DEL | Run Governed Delivery Adapter','VAL | Email Delivery Requested?','DEL | Run Governed Email Delivery Adapter','CTX | Attach Delivery Result'} <= an
code=next(n for n in agent['nodes'] if n['name']=='CTX | Interpret Report Request')['parameters']['jsCode']
assert "delivery_channel must be api, slack, or email" in code
prep=next(n for n in agent['nodes'] if n['name']=='CTX | Prepare Delivery Request')['parameters']['jsCode']
assert "slack_delivery_requested" in prep and "email_delivery_requested" in prep
email_call=next(n for n in agent['nodes'] if n['name']=='DEL | Run Governed Email Delivery Adapter')
assert email_call['parameters']['workflowId']['value']=='REVINTV2EMAIL01'
slack_gate=agent['connections']['VAL | Slack Delivery Requested?']['main']
assert slack_gate[1][0]['node']=='VAL | Email Delivery Requested?'
email_gate=agent['connections']['VAL | Email Delivery Requested?']['main']
assert email_gate[0][0]['node']=='DEL | Run Governed Email Delivery Adapter'
assert email_gate[1][0]['node']=='AUD | Log Report Result'
ret=next(n for n in agent['nodes'] if n['name']=='DEL | Return Report Response')
assert "CTX | Attach Delivery Result" in ret['parameters']['responseBody']
print('PASS: Slack + Gmail delivery workflow structure and Agent Core routing are bounded.')
PY

echo "PASS: delivery defaults disabled."
echo "PASS: trusted destination resolves only after explicit enablement."
echo "PASS: delivery is role-gated and sales-rep delivery fails closed."
echo "PASS: reporting reader can resolve delivery without reading destination registry."

grep -q "'slack_delivery'" "$RELIABILITY_SEED"
grep -q "60, false" "$RELIABILITY_SEED"
grep -q "SET active=\$enabled" "$DEPLOY_SCRIPT"
grep -q "WHERE component_key='slack_delivery'" "$DEPLOY_SCRIPT"
grep -q "SET active=\$ENABLE" "$CONFIGURE_SCRIPT"
grep -q "WHERE component_key='slack_delivery'" "$CONFIGURE_SCRIPT"
echo "PASS: safe-disabled Slack delivery is excluded from active reliability/observability state."

echo "PASS: reusable Agent V2 multi-channel delivery adapter verification passed."

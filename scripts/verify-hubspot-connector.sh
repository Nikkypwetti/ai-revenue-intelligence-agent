#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-HUBSPOT-01.json"
SYS_WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SYS-01.json"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  REPORTING_DB_ADMIN_USER REPORTING_DB_NAME
  REPORTING_DB_READER_USER REPORTING_DB_READER_PASSWORD
  CONNECTOR_DB_WRITER_USER CONNECTOR_DB_WRITER_PASSWORD
  AUDIT_DB_WRITER_USER AUDIT_DB_WRITER_PASSWORD
  CLIENT_CURRENCY N8N_DB_USER N8N_DB_NAME
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or uses a placeholder."
    exit 1
  fi
done
[[ "$CLIENT_CURRENCY" =~ ^[A-Z]{3}$ ]] || { echo "FAIL: CLIENT_CURRENCY must be a three-letter uppercase code."; exit 1; }

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

psql_admin() {
  "${compose[@]}" exec -T reporting-db psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" "$@"
}
psql_reader() {
  "${compose[@]}" exec -T -e PGPASSWORD="$REPORTING_DB_READER_PASSWORD" reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_READER_USER" -d "$REPORTING_DB_NAME" "$@"
}
psql_writer() {
  "${compose[@]}" exec -T -e PGPASSWORD="$CONNECTOR_DB_WRITER_PASSWORD" reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$CONNECTOR_DB_WRITER_USER" -d "$REPORTING_DB_NAME" "$@"
}
psql_audit() {
  "${compose[@]}" exec -T -e PGPASSWORD="$AUDIT_DB_WRITER_PASSWORD" reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$AUDIT_DB_WRITER_USER" -d "$REPORTING_DB_NAME" "$@"
}

cleanup() {
  psql_admin -c "
    DELETE FROM audit.agent_events
    WHERE event_id='HUBSPOT-VERIFY-COMPLETE';

    DELETE FROM reporting.deals
    WHERE connector_key='hubspot_primary'
      AND source_record_id LIKE 'hubspot-verify-%';

    DELETE FROM governance.connector_sync_state
    WHERE connector_key='hubspot_primary';

    DELETE FROM governance.circuit_state
    WHERE component_key='hubspot_sync';

    UPDATE governance.reliability_policy
    SET active=false, updated_at=now()
    WHERE component_key='hubspot_sync';

    UPDATE governance.connector_registry
    SET active=false, updated_at=now()
    WHERE connector_key='hubspot_primary';
  " >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

bash "$ROOT_DIR/scripts/init-hubspot-connector.sh"

surface_state="$(psql_admin -c "
  SELECT
    (to_regclass('governance.connector_sync_state') IS NOT NULL)::int || '|' ||
    (to_regprocedure('governance.get_connector_sync_context(text,timestamptz)') IS NOT NULL)::int || '|' ||
    (to_regprocedure('ingestion.ingest_deal_batch_from_source(text,jsonb)') IS NOT NULL)::int || '|' ||
    (to_regprocedure('governance.record_connector_sync_completion(text,text,timestamptz,timestamptz,timestamptz,integer,integer,integer,timestamptz)') IS NOT NULL)::int;
")"
[[ "$surface_state" == "1|1|1|1" ]] || {
  echo "FAIL: HubSpot connector database surfaces are incomplete."
  exit 1
}

connector_state="$(psql_admin -c "
  SELECT active::int || '|' || connector_type || '|' || contract_version || '|' ||
         (SELECT count(*) FROM governance.connector_field_mapping
          WHERE connector_key='hubspot_primary') || '|' ||
         (SELECT count(*) FROM governance.connector_value_mapping
          WHERE connector_key='hubspot_primary')
  FROM governance.connector_registry
  WHERE connector_key='hubspot_primary';
")"
[[ "$connector_state" == "0|hubspot|1|11|3" ]] || {
  echo "FAIL: disabled HubSpot connector mapping is not correct."
  exit 1
}

policy_state="$(psql_admin -c "
  SELECT workflow_id || '|' || max_attempts || '|' || retry_delay_ms || '|' || active::int
  FROM governance.reliability_policy
  WHERE component_key='hubspot_sync';
")"
[[ "$policy_state" == "REVINTV2HUBSPOT01|3|2000|0" ]] || {
  echo "FAIL: HubSpot reliability policy is not safely disabled by default."
  exit 1
}

permission_state="$(psql_admin -c "
  SELECT
    has_function_privilege('$REPORTING_DB_READER_USER','governance.get_connector_sync_context(text,timestamptz)','EXECUTE')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','governance.connector_sync_state','SELECT')::int || '|' ||
    has_function_privilege('$CONNECTOR_DB_WRITER_USER','ingestion.ingest_deal_batch_from_source(text,jsonb)','EXECUTE')::int || '|' ||
    has_table_privilege('$CONNECTOR_DB_WRITER_USER','reporting.deals','INSERT')::int || '|' ||
    has_table_privilege('$CONNECTOR_DB_WRITER_USER','reporting.deals','SELECT')::int || '|' ||
    has_function_privilege('$AUDIT_DB_WRITER_USER','governance.record_connector_sync_completion(text,text,timestamptz,timestamptz,timestamptz,integer,integer,integer,timestamptz)','EXECUTE')::int;
")"
[[ "$permission_state" == "1|0|1|0|0|1" ]] || {
  echo "FAIL: HubSpot least-privilege database boundary is incorrect."
  exit 1
}

psql_admin -c "
  UPDATE governance.connector_registry
  SET active=true, updated_at=now()
  WHERE connector_key='hubspot_primary';

  UPDATE governance.reliability_policy
  SET active=true, updated_at=now()
  WHERE component_key='hubspot_sync';

  INSERT INTO governance.circuit_state(component_key)
  VALUES ('hubspot_sync')
  ON CONFLICT (component_key) DO NOTHING;
" >/dev/null

context_state="$(psql_reader -c "
  SELECT
    (ctx->>'connector_key') || '|' ||
    (ctx->>'currency_code') || '|' ||
    (ctx->'reliability_gate'->>'allowed')
  FROM (SELECT governance.get_connector_sync_context('hubspot_primary') AS ctx) s;
")"
[[ "$context_state" == "hubspot_primary|$CLIENT_CURRENCY|true" ]] || {
  echo "FAIL: reporting reader could not resolve bounded HubSpot sync context."
  exit 1
}

batch_state="$(psql_writer -c "
  SELECT ingestion.ingest_deal_batch_from_source(
    'hubspot_primary',
    jsonb_build_array(
      jsonb_build_object(
        'source_record_id','hubspot-verify-open',
        'source_payload',jsonb_build_object(
          'dealname','HubSpot Verify Open',
          'amount','1250',
          'deal_currency_code','$CLIENT_CURRENCY',
          'dealstage','verify-open-stage',
          'revint_stage_category','open',
          'hubspot_owner_id','verify-owner',
          'hs_analytics_source','OFFLINE',
          'createdate','2026-09-01T09:00:00Z',
          'closedate','2026-10-15T00:00:00Z',
          'hs_lastmodifieddate','2026-09-28T08:00:00Z'
        )
      ),
      jsonb_build_object(
        'source_record_id','hubspot-verify-won',
        'source_payload',jsonb_build_object(
          'dealname','HubSpot Verify Won',
          'amount','2500',
          'deal_currency_code','$CLIENT_CURRENCY',
          'dealstage','verify-won-stage',
          'revint_stage_category','won',
          'hubspot_owner_id','verify-owner',
          'hs_analytics_source','REFERRALS',
          'createdate','2026-09-02T09:00:00Z',
          'closedate','2026-09-27T10:00:00Z',
          'hs_lastmodifieddate','2026-09-27T10:30:00Z'
        )
      )
    )
  )->>'processed_count';
")"
[[ "$batch_state" == "2" ]] || {
  echo "FAIL: controlled HubSpot batch gateway did not ingest both fixtures."
  exit 1
}

canonical_state="$(psql_admin -c "
  SELECT
    count(*) || '|' ||
    count(*) FILTER (WHERE stage_category='open' AND closed_at IS NULL) || '|' ||
    count(*) FILTER (WHERE stage_category='won' AND closed_at IS NOT NULL) || '|' ||
    sum(amount)::text
  FROM reporting.deals
  WHERE connector_key='hubspot_primary'
    AND source_record_id LIKE 'hubspot-verify-%';
")"
[[ "$canonical_state" == "2|1|1|3750.00" ]] || {
  echo "FAIL: HubSpot fixtures did not normalize into the canonical deal contract."
  exit 1
}

completion_state="$(psql_audit -c "
  SELECT governance.record_connector_sync_completion(
    'HUBSPOT-VERIFY-COMPLETE',
    'hubspot_primary',
    now() - interval '1 hour',
    now(),
    now(),
    2,2,0
  )->>'status';
")"
[[ "$completion_state" == "recorded" ]] || {
  echo "FAIL: HubSpot sync completion was not persisted through the audit boundary."
  exit 1
}

state_state="$(psql_admin -c "
  SELECT
    last_record_count || '|' || last_rejected_count || '|' ||
    (watermark IS NOT NULL)::int
  FROM governance.connector_sync_state
  WHERE connector_key='hubspot_primary';
")"
[[ "$state_state" == "2|0|1" ]] || {
  echo "FAIL: HubSpot incremental cursor was not recorded."
  exit 1
}

python3 - "$WORKFLOW" "$SYS_WORKFLOW" <<'PY'
import json, re, sys
workflow = json.load(open(sys.argv[1]))[0]
system = json.load(open(sys.argv[2]))[0]
nodes = {n["name"]: n for n in workflow["nodes"]}

assert workflow["id"] == "REVINTV2HUBSPOT01"
assert workflow["active"] is False
assert workflow["settings"]["errorWorkflow"] == "REVINTV2SYSERROR01"

schedule = nodes["INT | Fifteen-Minute HubSpot Sync"]
rule = schedule["parameters"]["rule"]["interval"][0]
assert rule["field"] == "minutes" and rule["minutesInterval"] == 15

http = nodes["SRC | Fetch HubSpot Deals"]
assert http["parameters"]["url"] == "https://api.hubapi.com/crm/objects/2026-03/deals/search"
assert http["credentials"]["hubspotAppToken"]["id"] == "REVINTHUBSPOTRO001"
pagination = http["parameters"]["options"]["pagination"]["pagination"]
assert pagination["limitPagesFetched"] is True
assert pagination["maxRequests"] == 50
assert pagination["requestInterval"] >= 1000
assert http["retryOnFail"] is True and http["maxTries"] == 3

normalize = nodes["VAL | Normalize HubSpot Deals"]["parameters"]["jsCode"]
for required in ("hs_is_closed_won", "hs_is_closed", "revint_stage_category"):
    assert required in normalize
assert "const sourceCurrency = String(p.deal_currency_code ?? '').trim().toUpperCase();" in normalize
assert "const currency = sourceCurrency || expectedCurrency;" in normalize
assert "currency === expectedCurrency" in normalize

batch = nodes["DB | Ingest HubSpot Batch"]["parameters"]["query"]
assert "ingest_deal_batch_from_source" in batch
audit = nodes["AUD | Complete HubSpot Sync"]["parameters"]["query"]
assert "record_connector_sync_completion" in audit

system_code = next(
    n["parameters"]["jsCode"]
    for n in system["nodes"]
    if n["name"] == "SYS | Normalize Terminal Failure"
)
assert "REVINTV2HUBSPOT01: 'hubspot_sync'" in system_code

serialized = json.dumps(workflow)
for pattern in (r"pat-[A-Za-z0-9_-]+", r"Bearer\s+[A-Za-z0-9._-]{12,}"):
    assert not re.search(pattern, serialized, re.I)

print("PASS: HubSpot workflow is bounded, credential-referenced, and disabled by default.")
print("PASS: current HubSpot API endpoint, pagination ceiling, and retry controls are present.")
print("PASS: stage classification is deterministic and no secret is embedded in workflow JSON.")
PY


node - "$WORKFLOW" "$CLIENT_CURRENCY" <<'NODETEST'
const fs = require('fs');
const workflow = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))[0];
const expectedCurrency = process.argv[3];
const normalize = workflow.nodes.find(n => n.name === 'VAL | Normalize HubSpot Deals').parameters.jsCode;
const context = {
  connector_key: 'hubspot_primary',
  currency_code: expectedCurrency,
  query_start_at: '2026-09-28T11:00:00.000Z',
  query_end_at: '2026-09-28T12:00:00.000Z'
};
const records = [
  {
    id: 'currency-default',
    properties: {
      dealname: 'Default Currency',
      amount: '100',
      deal_currency_code: '',
      dealstage: 'open-stage',
      hs_lastmodifieddate: '2026-09-28T11:30:00.000Z',
      createdate: '2026-09-28T10:00:00.000Z',
      closedate: null,
      hs_is_closed: false,
      hs_is_closed_won: false
    }
  },
  {
    id: 'currency-conflict',
    properties: {
      dealname: 'Conflicting Currency',
      amount: '200',
      deal_currency_code: expectedCurrency === 'USD' ? 'EUR' : 'USD',
      dealstage: 'open-stage',
      hs_lastmodifieddate: '2026-09-28T11:40:00.000Z',
      createdate: '2026-09-28T10:00:00.000Z',
      closedate: null,
      hs_is_closed: false,
      hs_is_closed_won: false
    }
  }
];
const dollar = () => ({ first: () => ({ json: { sync_context: context } }) });
const input = { all: () => [{ json: { results: records } }] };
const result = new Function('$', '$input', normalize)(dollar, input)[0].json;
if (result.record_count !== 1 || result.rejected_count !== 1) {
  throw new Error('currency normalization counts are incorrect');
}
if (result.records[0].source_payload.deal_currency_code !== expectedCurrency) {
  throw new Error('missing HubSpot currency did not fall back to governed currency');
}
console.log('PASS: missing HubSpot deal currency defaults to governed currency while explicit conflicts are rejected.');
NODETEST

for script in \
  "$ROOT_DIR/scripts/init-hubspot-connector.sh" \
  "$ROOT_DIR/scripts/import-hubspot-runtime-credential.sh" \
  "$ROOT_DIR/scripts/deploy-hubspot-connector.sh" \
  "$ROOT_DIR/scripts/verify-hubspot-connector.sh"; do
  bash -n "$script"
done

grep -q 'run --rm --no-deps -T n8n' "$ROOT_DIR/scripts/import-hubspot-runtime-credential.sh" || {
  echo "FAIL: HubSpot credential import is not isolated from the long-running n8n process."
  exit 1
}
grep -Fq '"${compose[@]}" stop n8n' "$ROOT_DIR/scripts/deploy-hubspot-connector.sh" || {
  echo "FAIL: HubSpot deployment does not stop Agent v2 n8n before CLI mutation."
  exit 1
}
grep -q 'set_connector_state false' "$ROOT_DIR/scripts/deploy-hubspot-connector.sh" || {
  echo "FAIL: HubSpot deployment is not fail-closed while runtime assets are prepared."
  exit 1
}
grep -q 'set_connector_state true' "$ROOT_DIR/scripts/deploy-hubspot-connector.sh" || {
  echo "FAIL: HubSpot deployment does not activate governance after runtime health."
  exit 1
}
grep -q 'EGRESS_DNS_PRIMARY' "$ROOT_DIR/deploy/docker-compose.yml" || {
  echo "FAIL: Agent v2 outbound connector DNS is not configurable."
  exit 1
}
grep -q '^EGRESS_DNS_PRIMARY=1.1.1.1$' "$ROOT_DIR/deploy/.env.example" || {
  echo "FAIL: example environment does not document the primary egress DNS setting."
  exit 1
}
grep -q '^EGRESS_DNS_SECONDARY=8.8.8.8$' "$ROOT_DIR/deploy/.env.example" || {
  echo "FAIL: example environment does not document the secondary egress DNS setting."
  exit 1
}

if bash "$ROOT_DIR/scripts/deploy-hubspot-connector.sh" \
  --confirm WRONG_TOKEN >/tmp/revint-hubspot-guard.out 2>&1; then
  echo "FAIL: HubSpot activation accepted an invalid confirmation token."
  exit 1
fi
grep -q 'activation confirmation token is missing or incorrect' \
  /tmp/revint-hubspot-guard.out || {
    echo "FAIL: HubSpot activation guard failed for an unexpected reason."
    exit 1
  }
rm -f /tmp/revint-hubspot-guard.out

bash "$ROOT_DIR/scripts/verify-runtime-isolation.sh"

echo "PASS: controlled batch ingestion reuses the canonical Stage 3 mapping gateway."
echo "PASS: sync cursor advances only through the dedicated audit-writer completion function."
echo "PASS: Reporting RO, Connector Writer, and Audit Writer retain separate privilege boundaries."
echo "PASS: explicit activation guard prevents accidental live HubSpot polling."
echo "PASS: Agent v2 runtime isolation verification passed."

cleanup
bash "$ROOT_DIR/scripts/verify-external-sso.sh"

echo "PASS: HubSpot connector foundation verification passed."

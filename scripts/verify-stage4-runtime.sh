#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT_DIR/deploy/.env"
COMPOSE_FILE="$ROOT_DIR/deploy/docker-compose.yml"
ENDPOINT="http://127.0.0.1:5681/webhook/revint/v2/deals"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

set -- REPORTING_DB_ADMIN_USER REPORTING_DB_NAME   N8N_DB_USER N8N_DB_NAME REPORTING_DB_READER_USER   AUDIT_DB_WRITER_USER CONNECTOR_DB_WRITER_USER   REST_INGEST_API_KEY CLIENT_CURRENCY

for name in "$@"; do
  value="$(printenv "$name" 2>/dev/null || true)"
  if [[ -z "$value" || "$value" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done
psql_n8n() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n-db     psql -X -q -A -t -v ON_ERROR_STOP=1     -U "$N8N_DB_USER" -d "$N8N_DB_NAME" "$@"
}

psql_admin() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db     psql -X -q -A -t -v ON_ERROR_STOP=1     -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" "$@"
}

cleanup() {
  psql_admin -c "
    DELETE FROM audit.agent_events
    WHERE stage='stage4'
      AND actor='n8n_rest_connector'
      AND payload->>'source_record_id' LIKE 'stage4-verify-%';
    DELETE FROM reporting.deals
    WHERE connector_key='rest_ingestion_api'
      AND source_record_id LIKE 'stage4-verify-%';
  " >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
credential_count="$(psql_n8n -c "
  SELECT count(*) FROM credentials_entity
  WHERE id IN (
    'REVINTPGREPORTRO001',
    'REVINTPGAUDITWR001',
    'REVINTPGINGESTWR001',
    'REVINTRESTHEADER001'
  );
")"
[[ "$credential_count" == "4" ]] || {
  echo "FAIL: expected four Stage 4 runtime credentials."
  exit 1
}

plaintext_count="$(psql_n8n -c "
  SELECT count(*) FROM credentials_entity
  WHERE id IN (
    'REVINTPGREPORTRO001',
    'REVINTPGAUDITWR001',
    'REVINTPGINGESTWR001',
    'REVINTRESTHEADER001'
  ) AND data LIKE '{%';
")"
[[ "$plaintext_count" == "0" ]] || {
  echo "FAIL: a Stage 4 credential looks plaintext in n8n storage."
  exit 1
}
owner_count="$(psql_n8n -c "
  SELECT count(*)
  FROM credentials_entity c
  JOIN shared_credentials sc ON sc.\"credentialsId\"=c.id
  JOIN project p ON p.id=sc.\"projectId\"
  WHERE c.id IN (
    'REVINTPGREPORTRO001',
    'REVINTPGAUDITWR001',
    'REVINTPGINGESTWR001',
    'REVINTRESTHEADER001'
  )
    AND sc.role='credential:owner'
    AND p.type='personal';
")"
[[ "$owner_count" == "4" ]] || {
  echo "FAIL: Stage 4 credentials are not owned by the personal project."
  exit 1
}

workflow_state="$(psql_n8n -c "
  SELECT active::int || '|' ||
         (\"versionId\" = \"activeVersionId\")::int
  FROM workflow_entity
  WHERE id='REVINTV2RESTINGEST01';
")"
[[ "$workflow_state" == "1|1" ]] || {
  echo "FAIL: Stage 4 workflow is not active on its current version."
  exit 1
}
webhook_count="$(psql_n8n -c "
  SELECT count(*)
  FROM webhook_entity
  WHERE \"workflowId\"='REVINTV2RESTINGEST01'
    AND \"webhookPath\"='revint/v2/deals'
    AND method='POST';
")"
[[ "$webhook_count" == "1" ]] || {
  echo "FAIL: Stage 4 production webhook is not registered exactly once."
  exit 1
}

connector_state="$(psql_admin -c "
  SELECT active::int || '|' || contract_version
  FROM governance.connector_registry
  WHERE connector_key='rest_ingestion_api';
")"
[[ "$connector_state" == "1|1" ]] || {
  echo "FAIL: REST ingestion connector is not active on contract version 1."
  exit 1
}
if ! ss -ltn | grep -qE '127\.0\.0\.1:5681|0\.0\.0\.0:5681|\[::\]:5681'; then
  echo "FAIL: Agent v2 is not listening on port 5681."
  exit 1
fi

if ! ss -ltn | grep -qE ':5678[[:space:]]'; then
  echo "FAIL: protected old local n8n listener on port 5678 is missing."
  exit 1
fi

health="$(curl -fsS --max-time 10 http://127.0.0.1:5681/healthz)"
[[ "$health" == *'"status":"ok"'* ]] || {
  echo "FAIL: Agent v2 health endpoint is not healthy."
  exit 1
}

python3 - <<'PY'
import json
import os
import urllib.error
import urllib.request

url = "http://127.0.0.1:5681/webhook/revint/v2/deals"
key = os.environ["REST_INGEST_API_KEY"]
currency = os.environ["CLIENT_CURRENCY"]
def request(payload, authenticated=True):
    headers = {"Content-Type": "application/json"}
    if authenticated:
        headers["X-Revint-Ingest-Key"] = key
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read().decode()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()
        try:
            body = json.loads(raw)
        except Exception:
            body = {"raw": raw}
        return exc.code, body

status, _ = request({"source_record_id": "stage4-verify-unauth"}, False)
if status != 403:
    raise SystemExit(f"FAIL: unauthenticated request returned {status}, expected 403")
base = {
    "deal_name": "Stage 4 Verification",
    "currency_code": currency,
    "stage_name": "Closed Won",
    "stage_category": "won",
    "sales_rep": "Runtime Verification",
    "lead_source": "rest_api",
    "created_at": "2026-09-20T09:00:00Z",
    "expected_close_date": "2026-09-27T10:00:00Z",
    "closed_at": "2026-09-27T10:00:00Z",
    "source_updated_at": "2026-09-27T10:30:00Z",
}

def assert_response(label, payload, expected_status, error_code=None):
    status, body = request(payload)
    if status != expected_status:
        raise SystemExit(
            f"FAIL: {label} returned HTTP {status}, expected {expected_status}"
        )
    if error_code:
        codes = {
            item.get("code")
            for item in body.get("errors", [])
            if isinstance(item, dict)
        }
        if error_code not in codes:
            raise SystemExit(f"FAIL: {label} did not return {error_code}")
    elif body.get("status") != "success":
        raise SystemExit(f"FAIL: {label} did not return status=success")
    return body

assert_response(
    "initial upsert",
    {**base, "source_record_id": "stage4-verify-won", "amount": 1200},
    200,
)
assert_response(
    "idempotent update",
    {**base, "source_record_id": "stage4-verify-won", "amount": 1500},
    200,
)
assert_response(
    "bad stage",
    {
        **base,
        "source_record_id": "stage4-verify-bad-stage",
        "amount": 10,
        "stage_category": "unknown",
    },
    400,
    "STAGE_CATEGORY_INVALID",
)
wrong_currency = "EUR" if currency != "EUR" else "USD"
assert_response(
    "bad currency",
    {
        **base,
        "source_record_id": "stage4-verify-bad-currency",
        "amount": 10,
        "currency_code": wrong_currency,
    },
    400,
    "CURRENCY_INVALID",
)

missing_close = {
    **base,
    "source_record_id": "stage4-verify-missing-close",
    "amount": 10,
}
missing_close.pop("closed_at", None)
assert_response(
    "missing close",
    missing_close,
    400,
    "TIMESTAMP_REQUIRED",
)
assert_response(
    "open deal",
    {
        **base,
        "source_record_id": "stage4-verify-open",
        "amount": 2000,
        "stage_name": "Prospecting",
        "stage_category": "open",
        "closed_at": "2026-09-27T10:00:00Z",
        "expected_close_date": "2026-10-15T00:00:00Z",
    },
    200,
)

print("PASS: authenticated REST endpoint accepts governed deal ingestion.")
print("PASS: unauthenticated requests are rejected before workflow execution.")
print("PASS: validation rejects bad stage, currency, and closed-deal timestamps.")
PY

won_state="$(psql_admin -c "
  SELECT count(*) || '|' || max(amount)::text
  FROM reporting.deals
  WHERE connector_key='rest_ingestion_api'
    AND source_record_id='stage4-verify-won';
")"
[[ "$won_state" == "1|1500.00" ]] || {
  echo "FAIL: REST source-record upsert is not idempotent."
  exit 1
}

open_state="$(psql_admin -c "
  SELECT count(*) || '|' ||
         count(*) FILTER (WHERE closed_at IS NULL)
  FROM reporting.deals
  WHERE connector_key='rest_ingestion_api'
    AND source_record_id='stage4-verify-open';
")"
[[ "$open_state" == "1|1" ]] || {
  echo "FAIL: open REST deal did not normalize closed_at to NULL."
  exit 1
}

rejected_count="$(psql_admin -c "
  SELECT count(*)
  FROM reporting.deals
  WHERE connector_key='rest_ingestion_api'
    AND source_record_id IN (
      'stage4-verify-bad-stage',
      'stage4-verify-bad-currency',
      'stage4-verify-missing-close'
    );
")"
[[ "$rejected_count" == "0" ]] || {
  echo "FAIL: rejected REST payloads reached canonical reporting data."
  exit 1
}

audit_count="$(psql_admin -c "
  SELECT count(*)
  FROM audit.agent_events
  WHERE stage='stage4'
    AND actor='n8n_rest_connector'
    AND payload->>'source_record_id' IN (
      'stage4-verify-won',
      'stage4-verify-open'
    );
")"
[[ "$audit_count" == "3" ]] || {
  echo "FAIL: expected three Stage 4 success audit events."
  exit 1
}

echo "PASS: REST source-record upserts are idempotent."
echo "PASS: open deals force canonical closed_at to NULL."
echo "PASS: rejected payloads do not reach reporting.deals."
echo "PASS: successful ingestion events are written through the audit credential."

bash "$ROOT_DIR/scripts/verify-stage3-contract.sh"
echo "PASS: Stage 4 runtime integration verification passed."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
CONNECTOR_CONFIG_FILE="${CONNECTOR_CONFIG_FILE:-}"
VALIDATE_ONLY=0

usage() {
  cat <<'EOF'
Usage:
  CONNECTOR_CONFIG_FILE=config/salesforce-connector.example.json \
    bash scripts/apply-client-connector-config.sh [--validate-only]

The configuration contains mapping metadata only. Never store credentials in it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --validate-only) VALIDATE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "FAIL: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$CONNECTOR_CONFIG_FILE" ]] || { usage; echo "FAIL: CONNECTOR_CONFIG_FILE is required." >&2; exit 1; }
[[ -f "$CONNECTOR_CONFIG_FILE" ]] || { echo "FAIL: config not found: $CONNECTOR_CONFIG_FILE" >&2; exit 1; }

config_json="$(python3 - "$CONNECTOR_CONFIG_FILE" <<'PY'
import json, re, sys
from pathlib import Path

path = Path(sys.argv[1])
doc = json.loads(path.read_text())

if doc.get("schema_version") != 2:
    raise SystemExit("FAIL: client connector config schema_version must be 2.")

connectors = doc.get("connectors")
if not isinstance(connectors, list) or not connectors:
    raise SystemExit("FAIL: connector config must contain at least one connector.")

allowed_types = {"hubspot","salesforce","airtable","postgresql","google_sheets","billing","rest_api"}
allowed_objects = {"deal","funnel"}
deal_fields = {
    "deal_name","amount","currency_code","stage_name","stage_category",
    "sales_rep","lead_source","created_at","expected_close_date","closed_at",
    "source_updated_at","probability_percent","forecast_category","account_key",
    "segment","region","industry","campaign","qualified_at","opportunity_at",
    "proposal_sent_at","stage_entered_at","last_activity_at","next_activity_at",
    "first_response_at","sla_due_at","lost_reason","annual_contract_value",
    "monthly_recurring_revenue","list_amount","discount_percent"
}
funnel_fields = {
    "sales_rep","lead_source","campaign","segment","region","industry",
    "created_at","first_response_at","mql_at","sql_at","opportunity_at",
    "won_at","lost_at","source_updated_at"
}
allowed_transforms = {"text","numeric","uppercase","timestamp","value_map"}
secret_key = re.compile(r"(password|secret|token|credential|api[_-]?key|access[_-]?key)", re.I)

def reject_secrets(value, trail="root"):
    if isinstance(value, dict):
        for k, v in value.items():
            if secret_key.search(str(k)):
                raise SystemExit(f"FAIL: secret-like field is not allowed in connector config: {trail}.{k}")
            reject_secrets(v, f"{trail}.{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            reject_secrets(v, f"{trail}[{i}]")

reject_secrets(doc)

seen_keys=set()
for c in connectors:
    if not isinstance(c, dict):
        raise SystemExit("FAIL: every connector must be an object.")
    key=c.get("connector_key")
    if not isinstance(key,str) or not re.fullmatch(r"[a-z][a-z0-9_]{2,63}",key):
        raise SystemExit(f"FAIL: invalid connector_key: {key!r}")
    if key in seen_keys:
        raise SystemExit(f"FAIL: duplicate connector_key: {key}")
    seen_keys.add(key)
    ctype=c.get("connector_type")
    obj=c.get("object_type")
    if ctype not in allowed_types:
        raise SystemExit(f"FAIL: unsupported connector_type for {key}: {ctype!r}")
    if obj not in allowed_objects:
        raise SystemExit(f"FAIL: unsupported object_type for {key}: {obj!r}")
    if c.get("contract_version") != 1:
        raise SystemExit(f"FAIL: contract_version=1 required for {key}.")
    if not isinstance(c.get("active"),bool):
        raise SystemExit(f"FAIL: active must be boolean for {key}.")
    if not isinstance(c.get("display_name"),str) or not c["display_name"].strip():
        raise SystemExit(f"FAIL: display_name required for {key}.")

    allowed_fields = deal_fields if obj=="deal" else funnel_fields
    required_fields = {"amount","currency_code","stage_name","stage_category"} if obj=="deal" else {"created_at"}
    mappings=c.get("field_mappings")
    if not isinstance(mappings,list) or not mappings:
        raise SystemExit(f"FAIL: field_mappings required for {key}.")
    seen=set()
    for m in mappings:
        field=m.get("canonical_field")
        if field not in allowed_fields:
            raise SystemExit(f"FAIL: unsupported canonical_field {field!r} for {key}/{obj}.")
        if field in seen:
            raise SystemExit(f"FAIL: duplicate canonical_field {field} for {key}.")
        seen.add(field)
        if m.get("transform_key") not in allowed_transforms:
            raise SystemExit(f"FAIL: unsupported transform for {key}.{field}.")
        if not m.get("source_field") and m.get("default_value") in (None,""):
            raise SystemExit(f"FAIL: source_field or default_value required for {key}.{field}.")
        if "required" in m and not isinstance(m["required"],bool):
            raise SystemExit(f"FAIL: required must be boolean for {key}.{field}.")
    missing=sorted(required_fields-seen)
    if missing:
        raise SystemExit(f"FAIL: {key} missing required mappings: {', '.join(missing)}")

    value_mappings=c.get("value_mappings",[])
    if not isinstance(value_mappings,list):
        raise SystemExit(f"FAIL: value_mappings must be a list for {key}.")
    if obj=="funnel" and value_mappings:
        raise SystemExit(f"FAIL: funnel connector {key} does not accept value_mappings.")
    for vm in value_mappings:
        if vm.get("canonical_field")!="stage_category":
            raise SystemExit(f"FAIL: only stage_category value mappings supported for {key}.")
        if vm.get("canonical_value") not in {"open","won","lost"}:
            raise SystemExit(f"FAIL: invalid stage category for {key}.")
        if not isinstance(vm.get("source_value"),str) or not vm["source_value"]:
            raise SystemExit(f"FAIL: source_value required for {key}.")

print(json.dumps(doc,separators=(",",":")))
PY
)"

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
  count="$(python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())["connectors"]))' <<<"$config_json")"
  echo "PASS: validated $count client connector configuration(s)."
  exit 0
fi

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist." >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for name in REPORTING_DB_ADMIN_USER REPORTING_DB_NAME; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || {
    echo "FAIL: $name is missing or placeholder." >&2
    exit 1
  }
done

connector_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())["connectors"]))' <<<"$config_json")"

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
  psql -X -q -v ON_ERROR_STOP=1 \
  -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" \
  -v config_json="$config_json" <<'SQL'
BEGIN;

WITH cfg AS (SELECT :'config_json'::jsonb AS doc),
connectors AS (
  SELECT value AS c FROM cfg, jsonb_array_elements(doc->'connectors')
)
INSERT INTO governance.connector_registry (
  connector_key, connector_type, display_name, object_type,
  contract_version, active, updated_at
)
SELECT
  c->>'connector_key', c->>'connector_type', c->>'display_name',
  c->>'object_type', (c->>'contract_version')::integer,
  (c->>'active')::boolean, now()
FROM connectors
ON CONFLICT (connector_key) DO UPDATE SET
  connector_type=EXCLUDED.connector_type,
  display_name=EXCLUDED.display_name,
  object_type=EXCLUDED.object_type,
  contract_version=EXCLUDED.contract_version,
  active=EXCLUDED.active,
  updated_at=now();

WITH cfg AS (SELECT :'config_json'::jsonb AS doc),
keys AS (
  SELECT value->>'connector_key' AS connector_key
  FROM cfg, jsonb_array_elements(doc->'connectors')
)
DELETE FROM governance.connector_field_mapping fm
USING keys k WHERE fm.connector_key=k.connector_key;

WITH cfg AS (SELECT :'config_json'::jsonb AS doc),
connectors AS (
  SELECT value AS c FROM cfg, jsonb_array_elements(doc->'connectors')
),
mappings AS (
  SELECT c->>'connector_key' connector_key, m
  FROM connectors
  CROSS JOIN LATERAL jsonb_array_elements(c->'field_mappings') m
)
INSERT INTO governance.connector_field_mapping (
  connector_key,canonical_field,source_field,transform_key,
  required,default_value,active
)
SELECT
  connector_key,m->>'canonical_field',NULLIF(m->>'source_field',''),
  m->>'transform_key',COALESCE((m->>'required')::boolean,false),
  NULLIF(m->>'default_value',''),COALESCE((m->>'active')::boolean,true)
FROM mappings;

WITH cfg AS (SELECT :'config_json'::jsonb AS doc),
keys AS (
  SELECT value->>'connector_key' connector_key
  FROM cfg, jsonb_array_elements(doc->'connectors')
)
DELETE FROM governance.connector_value_mapping vm
USING keys k WHERE vm.connector_key=k.connector_key;

WITH cfg AS (SELECT :'config_json'::jsonb AS doc),
connectors AS (
  SELECT value AS c FROM cfg, jsonb_array_elements(doc->'connectors')
),
mappings AS (
  SELECT c->>'connector_key' connector_key, vm
  FROM connectors
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(c->'value_mappings','[]'::jsonb)) vm
)
INSERT INTO governance.connector_value_mapping (
  connector_key,canonical_field,source_value,canonical_value,active
)
SELECT
  connector_key,vm->>'canonical_field',vm->>'source_value',
  vm->>'canonical_value',COALESCE((vm->>'active')::boolean,true)
FROM mappings;

COMMIT;
SQL

echo "PASS: applied $connector_count client connector configuration(s) without storing credentials."

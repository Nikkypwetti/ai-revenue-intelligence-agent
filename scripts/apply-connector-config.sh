#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
CONNECTOR_CONFIG_FILE="${CONNECTOR_CONFIG_FILE:-$ROOT_DIR/config/connectors.local.json}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL: $ENV_FILE does not exist."
  exit 1
fi

if [[ ! -f "$CONNECTOR_CONFIG_FILE" ]]; then
  echo "FAIL: connector configuration file not found: $CONNECTOR_CONFIG_FILE"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

config_json="$(python3 - "$CONNECTOR_CONFIG_FILE" <<'PY'
import json, re, sys
from pathlib import Path

path = Path(sys.argv[1])
doc = json.loads(path.read_text())

if doc.get("schema_version") != 1:
    raise SystemExit("FAIL: connector config schema_version must be 1.")

connectors = doc.get("connectors")
if not isinstance(connectors, list) or not connectors:
    raise SystemExit("FAIL: connector config must contain at least one connector.")

allowed_types = {"hubspot","salesforce","airtable","postgresql","google_sheets","billing","rest_api"}
allowed_fields = {
    "deal_name","amount","currency_code","stage_name","stage_category",
    "sales_rep","lead_source","created_at","expected_close_date",
    "closed_at","source_updated_at"
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

seen_keys = set()
for c in connectors:
    if not isinstance(c, dict):
        raise SystemExit("FAIL: every connector must be an object.")
    key = c.get("connector_key")
    if not isinstance(key, str) or not re.fullmatch(r"[a-z][a-z0-9_]{2,63}", key):
        raise SystemExit(f"FAIL: invalid connector_key: {key!r}")
    if key in seen_keys:
        raise SystemExit(f"FAIL: duplicate connector_key: {key}")
    seen_keys.add(key)
    if c.get("connector_type") not in allowed_types:
        raise SystemExit(f"FAIL: unsupported connector_type for {key}.")
    if not isinstance(c.get("display_name"), str) or not c["display_name"].strip():
        raise SystemExit(f"FAIL: display_name is required for {key}.")
    if c.get("object_type") != "deal":
        raise SystemExit(f"FAIL: Stage 3 supports object_type=deal only for {key}.")
    if c.get("contract_version") != 1:
        raise SystemExit(f"FAIL: Stage 3 supports contract_version=1 only for {key}.")
    if not isinstance(c.get("active"), bool):
        raise SystemExit(f"FAIL: active must be true/false for {key}.")

    mappings = c.get("field_mappings")
    if not isinstance(mappings, list) or not mappings:
        raise SystemExit(f"FAIL: field_mappings are required for {key}.")
    seen_fields = set()
    for m in mappings:
        field = m.get("canonical_field")
        if field not in allowed_fields:
            raise SystemExit(f"FAIL: unsupported canonical_field {field!r} for {key}.")
        if field in seen_fields:
            raise SystemExit(f"FAIL: duplicate canonical_field {field} for {key}.")
        seen_fields.add(field)
        if m.get("transform_key") not in allowed_transforms:
            raise SystemExit(f"FAIL: unsupported transform_key for {key}.{field}.")
        source_field = m.get("source_field")
        default_value = m.get("default_value")
        if not source_field and default_value in (None, ""):
            raise SystemExit(f"FAIL: source_field or default_value is required for {key}.{field}.")
        if "required" in m and not isinstance(m["required"], bool):
            raise SystemExit(f"FAIL: required must be true/false for {key}.{field}.")

    required_contract = {"amount","currency_code","stage_name","stage_category"}
    missing = sorted(required_contract - seen_fields)
    if missing:
        raise SystemExit(f"FAIL: {key} is missing required canonical mappings: {', '.join(missing)}")

    for vm in c.get("value_mappings", []):
        if vm.get("canonical_field") != "stage_category":
            raise SystemExit(f"FAIL: only stage_category value mappings are supported for {key}.")
        if vm.get("canonical_value") not in {"open","won","lost"}:
            raise SystemExit(f"FAIL: invalid canonical stage category for {key}.")
        if not isinstance(vm.get("source_value"), str) or not vm["source_value"]:
            raise SystemExit(f"FAIL: source_value is required for {key} stage mapping.")

print(json.dumps(doc, separators=(",", ":")))
PY
)"

connector_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())["connectors"]))' <<<"$config_json")"

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
  psql -X -q -v ON_ERROR_STOP=1 \
  -U "$REPORTING_DB_ADMIN_USER" \
  -d "$REPORTING_DB_NAME" \
  -v config_json="$config_json" <<'SQL'
BEGIN;

WITH cfg AS (
  SELECT :'config_json'::jsonb AS doc
),
connectors AS (
  SELECT value AS c
  FROM cfg, jsonb_array_elements(doc->'connectors')
)
INSERT INTO governance.connector_registry (
  connector_key, connector_type, display_name, object_type,
  contract_version, active, updated_at
)
SELECT
  c->>'connector_key',
  c->>'connector_type',
  c->>'display_name',
  c->>'object_type',
  (c->>'contract_version')::integer,
  (c->>'active')::boolean,
  now()
FROM connectors
ON CONFLICT (connector_key) DO UPDATE SET
  connector_type = EXCLUDED.connector_type,
  display_name = EXCLUDED.display_name,
  object_type = EXCLUDED.object_type,
  contract_version = EXCLUDED.contract_version,
  active = EXCLUDED.active,
  updated_at = now();

WITH cfg AS (
  SELECT :'config_json'::jsonb AS doc
),
connector_keys AS (
  SELECT value->>'connector_key' AS connector_key
  FROM cfg, jsonb_array_elements(doc->'connectors')
)
DELETE FROM governance.connector_field_mapping fm
USING connector_keys ck
WHERE fm.connector_key = ck.connector_key;

WITH cfg AS (
  SELECT :'config_json'::jsonb AS doc
),
connectors AS (
  SELECT value AS c
  FROM cfg, jsonb_array_elements(doc->'connectors')
),
mappings AS (
  SELECT
    c->>'connector_key' AS connector_key,
    m
  FROM connectors
  CROSS JOIN LATERAL jsonb_array_elements(c->'field_mappings') AS m
)
INSERT INTO governance.connector_field_mapping (
  connector_key, canonical_field, source_field, transform_key,
  required, default_value, active
)
SELECT
  connector_key,
  m->>'canonical_field',
  NULLIF(m->>'source_field',''),
  m->>'transform_key',
  COALESCE((m->>'required')::boolean, false),
  NULLIF(m->>'default_value',''),
  COALESCE((m->>'active')::boolean, true)
FROM mappings;

WITH cfg AS (
  SELECT :'config_json'::jsonb AS doc
),
connector_keys AS (
  SELECT value->>'connector_key' AS connector_key
  FROM cfg, jsonb_array_elements(doc->'connectors')
)
DELETE FROM governance.connector_value_mapping vm
USING connector_keys ck
WHERE vm.connector_key = ck.connector_key;

WITH cfg AS (
  SELECT :'config_json'::jsonb AS doc
),
connectors AS (
  SELECT value AS c
  FROM cfg, jsonb_array_elements(doc->'connectors')
),
value_mappings AS (
  SELECT
    c->>'connector_key' AS connector_key,
    vm
  FROM connectors
  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(c->'value_mappings','[]'::jsonb)
  ) AS vm
)
INSERT INTO governance.connector_value_mapping (
  connector_key, canonical_field, source_value, canonical_value, active
)
SELECT
  connector_key,
  vm->>'canonical_field',
  vm->>'source_value',
  vm->>'canonical_value',
  COALESCE((vm->>'active')::boolean, true)
FROM value_mappings;

COMMIT;
SQL

echo "PASS: applied $connector_count connector configuration(s) without storing credentials."

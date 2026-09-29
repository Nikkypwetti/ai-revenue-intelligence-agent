#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
CONFIG="${AIRTABLE_CONNECTOR_CONFIG_FILE:-$ROOT_DIR/config/connectors.local.json}"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
[[ -f "$CONFIG" ]] || { echo "FAIL: Airtable connector config does not exist: $CONFIG"; exit 1; }

bash "$ROOT_DIR/scripts/init-multi-crm-sync.sh"

python3 - "$CONFIG" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1]))
matches=[c for c in doc.get("connectors",[]) if c.get("connector_key")=="airtable_primary"]
if len(matches)!=1:
    raise SystemExit("FAIL: connectors.local.json must contain exactly one airtable_primary connector.")
c=matches[0]
for m in c.get("field_mappings",[]):
    sf=m.get("source_field")
    if isinstance(sf,str) and sf.startswith("CHANGE_ME_"):
        raise SystemExit("FAIL: Airtable connector still contains unresolved CHANGE_ME field mappings.")
for m in c.get("value_mappings",[]):
    sv=m.get("source_value")
    if isinstance(sv,str) and sv.startswith("CHANGE_ME_"):
        raise SystemExit("FAIL: Airtable connector still contains unresolved CHANGE_ME stage mappings.")
PY

# Initialization is fail-closed; force the connector inactive until deployment completes.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
python3 - "$CONFIG" "$tmp" <<'PY'
import json,sys
src,dst=sys.argv[1:3]
doc=json.load(open(src))
for c in doc["connectors"]:
    if c.get("connector_key")=="airtable_primary":
        c["active"]=False
json.dump(doc,open(dst,"w"),indent=2)
PY
CONNECTOR_CONFIG_FILE="$tmp" bash "$ROOT_DIR/scripts/apply-connector-config.sh"

echo "PASS: Airtable connector mapping initialized safe-disabled."

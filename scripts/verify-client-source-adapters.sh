#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])

for fn in ("REVINT-V2-SALESFORCE-01.json","REVINT-V2-AIRTABLE-01.json"):
    p=root/"workflows/runtime-templates"/fn
    w=json.loads(p.read_text())[0]
    assert w["active"] is False, fn
    expected = 12 if fn=="REVINT-V2-SALESFORCE-01.json" else 10
    assert len(w["nodes"]) == expected, (fn,len(w["nodes"]))
    assert all(str(n.get("notes","")).strip() for n in w["nodes"]), fn

sf=json.loads((root/"workflows/runtime-templates/REVINT-V2-SALESFORCE-01.json").read_text())[0]
src=next(n for n in sf["nodes"] if n["name"]=="SRC | Query Salesforce Opportunities")
assert src["type"]=="n8n-nodes-base.salesforce"
assert src["parameters"]["resource"]=="search"
assert src["parameters"]["operation"]=="query"
cred=src["credentials"]["salesforceOAuth2Api"]
assert cred["id"]=="REVINTSFRO001"

at=json.loads((root/"workflows/runtime-templates/REVINT-V2-AIRTABLE-01.json").read_text())[0]
src=next(n for n in at["nodes"] if n["name"]=="SRC | Read Airtable Lead Records")
assert src["type"]=="n8n-nodes-base.airtable"
assert src["parameters"]["operation"]=="search"
cred=src["credentials"]["airtableTokenApi"]
assert cred["id"]=="REVINTAIRTABLE001"

print("PASS: Salesforce/Airtable workflow templates are inactive, documented and source-read-only.")
PY

CONNECTOR_CONFIG_FILE="$ROOT_DIR/config/salesforce-connector.example.json" \
  bash "$ROOT_DIR/scripts/apply-client-connector-config.sh" --validate-only
CONNECTOR_CONFIG_FILE="$ROOT_DIR/config/airtable-funnel-connector.example.json" \
  bash "$ROOT_DIR/scripts/apply-client-connector-config.sh" --validate-only

echo "PASS: client source adapter static verification passed."

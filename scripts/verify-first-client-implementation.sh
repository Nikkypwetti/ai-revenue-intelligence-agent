#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT_DIR/config/first-client.connectors.example.json"
APPLY="$ROOT_DIR/scripts/apply-connector-config.sh"

python3 - "$CONFIG" <<'PY'
import json, re, sys
from pathlib import Path

doc=json.loads(Path(sys.argv[1]).read_text())
assert doc["schema_version"] == 1
connectors={c["connector_key"]:c for c in doc["connectors"]}
assert set(connectors) == {"hubspot_primary","salesforce_primary","airtable_primary"}

# Public reference configuration must never activate client sources.
assert all(c["active"] is False for c in connectors.values())

# HubSpot uses deterministic derived stage category and governed default currency behavior.
hub=connectors["hubspot_primary"]
hm={m["canonical_field"]:m for m in hub["field_mappings"]}
assert hm["stage_category"]["source_field"] == "revint_stage_category"
assert {v["source_value"] for v in hub["value_mappings"]} == {"open","won","lost"}

# AsterNova Salesforce stage model captured from the verified CRM build.
sf=connectors["salesforce_primary"]
expected={
 "Discovery":"open",
 "Technical Review":"open",
 "Proposal Sent":"open",
 "Negotiation":"open",
 "Closed Won":"won",
 "Closed Lost":"lost",
}
actual={v["source_value"]:v["canonical_value"] for v in sf["value_mappings"]}
assert actual == expected
sfm={m["canonical_field"]:m for m in sf["field_mappings"]}
assert sfm["amount"]["source_field"] == "Amount"
assert sfm["stage_name"]["source_field"] == "StageName"
assert sfm["sales_rep"]["source_field"] == "OwnerId"
assert sfm["source_updated_at"]["source_field"] == "LastModifiedDate"

# Airtable stays blocked until its live field schema is re-read after API quota reset.
air=connectors["airtable_primary"]
assert air["active"] is False
assert any(
    isinstance(m.get("source_field"),str) and m["source_field"].startswith("CHANGE_ME_")
    for m in air["field_mappings"]
)

secret_key=re.compile(r"(password|secret|token|credential|api[_-]?key|access[_-]?key)",re.I)
def walk(x,path="root"):
    if isinstance(x,dict):
        for k,v in x.items():
            assert not secret_key.search(str(k)), f"secret-like config key: {path}.{k}"
            walk(v,f"{path}.{k}")
    elif isinstance(x,list):
        for i,v in enumerate(x): walk(v,f"{path}[{i}]")
walk(doc)

print("PASS: first-client connector pack is secret-free and disabled by default.")
print("PASS: HubSpot deterministic stage-category contract is preserved.")
print("PASS: Salesforce AsterNova stage model maps deterministically to open/won/lost.")
print("PASS: Airtable remains fail-closed until live field schema verification.")
PY

grep -q '"airtable"' "$APPLY"
grep -q 'active connector .* unresolved source-field placeholder' "$APPLY"

bash -n "$APPLY"

echo "PASS: first-client static implementation verification passed."

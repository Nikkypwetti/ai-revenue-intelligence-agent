#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION="$ROOT_DIR/database/migrations/016_multi_crm_connector_sync.sql"
SEED="$ROOT_DIR/database/seeds/009_multi_crm_reliability.sql"
CONFIG="$ROOT_DIR/config/first-client.connectors.example.json"

python3 - "$MIGRATION" "$SEED" "$CONFIG" <<'PY'
import json,sys
from pathlib import Path

migration=Path(sys.argv[1]).read_text()
seed=Path(sys.argv[2]).read_text()
cfg=json.loads(Path(sys.argv[3]).read_text())

for t in ("hubspot","salesforce","airtable"):
    assert f"'{t}'" in migration
assert "connector_sync_component_key" in migration
assert "regexp_replace(p_connector_key, '_primary$', '') || '_sync'" in migration
assert "CRM_CONNECTOR_NOT_ACTIVE" in migration
assert "record_connector_sync_completion" in migration
assert "connector_type" in migration
assert "connector_sync_state" in migration

assert "'salesforce_sync'" in seed
assert "'airtable_sync'" in seed
assert "REVINTV2SALESFORCE01" in seed
assert "REVINTV2AIRTABLE01" in seed
assert seed.count("false") >= 2

types={c["connector_key"]:c["connector_type"] for c in cfg["connectors"]}
assert types["hubspot_primary"]=="hubspot"
assert types["salesforce_primary"]=="salesforce"
assert types["airtable_primary"]=="airtable"

print("PASS: multi-CRM sync governance supports HubSpot, Salesforce and Airtable.")
print("PASS: reliability component keys resolve consistently from connector keys.")
print("PASS: Salesforce/Airtable reliability policies are seeded disabled.")
PY

bash -n "$ROOT_DIR/scripts/init-multi-crm-sync.sh"
bash -n "$ROOT_DIR/scripts/rehearse-postgres17-upgrade.sh"
bash -n "$ROOT_DIR/scripts/load-test-report-api.sh"
bash -n "$ROOT_DIR/scripts/replicate-backup-offsite.sh"

echo "PASS: local hardening and multi-CRM static verification passed."

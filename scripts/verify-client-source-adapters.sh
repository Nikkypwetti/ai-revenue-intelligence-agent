#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
source "$ENV_FILE"
set +a
compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

state="$("${compose[@]}" exec -T reporting-db psql -X -q -A -t   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
SELECT c.connector_key||'|'||c.connector_type||'|'||c.active::int||'|'||
       r.read_enabled::int||'|'||r.write_enabled::int||'|'||COALESCE(r.blocked_reason,'')
FROM governance.connector_registry c
JOIN governance.connector_runtime_config r USING(connector_key)
WHERE c.connector_key IN ('salesforce_primary','airtable_primary')
ORDER BY c.connector_key;")"

grep -qx 'airtable_primary|airtable|0|0|0|AIRTABLE_API_BILLING_LIMIT' <<<"$state"
grep -qx 'salesforce_primary|salesforce|0|0|0|DEDICATED_CREDENTIAL_REQUIRED' <<<"$state"

workflow_state="$("${compose[@]}" exec -T n8n-db psql -X -q -A -F '|'   -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
SELECT id,active::int,jsonb_array_length(nodes::jsonb)
FROM workflow_entity
WHERE id IN ('REVINTV2SALESFORCE01','REVINTV2AIRTABLE01')
ORDER BY id;")"

printf '%s\n' "$workflow_state" | grep -Eq '^REVINTV2AIRTABLE01\|1\|10$'
printf '%s\n' "$workflow_state" | grep -Eq '^REVINTV2SALESFORCE01\|1\|10$'

cd "$ROOT_DIR"
python3 - <<'PY'
import json
from pathlib import Path
root=Path('.')
cases=[
 ('REVINT-V2-SALESFORCE-01.json','REVINTV2SALESFORCE01','salesforceOAuth2Api','REVINTSALESFORCERO001'),
 ('REVINT-V2-AIRTABLE-01.json','REVINTV2AIRTABLE01','airtableTokenApi','REVINTAIRTABLE001'),
]
for file,wid,ctype,cid in cases:
    w=json.loads((root/'workflows/runtime-templates'/file).read_text())[0]
    assert w['id']==wid and len(w['nodes'])==10
    assert all(n.get('notes') for n in w['nodes'])
    assert not any(n['type']=='n8n-nodes-base.webhook' for n in w['nodes'])
    assert any((n.get('credentials',{}).get(ctype,{}) or {}).get('id')==cid for n in w['nodes'])
print('PASS: staged CRM source adapters are internal, documented, dedicated-credential referenced and fail-closed.')
PY

bash "$ROOT_DIR/scripts/verify-runtime-isolation.sh" >/dev/null
echo "PASS: Salesforce/Airtable source-adapter staging verification passed."


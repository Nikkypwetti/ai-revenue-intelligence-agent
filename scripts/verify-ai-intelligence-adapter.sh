#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
source "$ENV_FILE"
set +a

required=(REPORTING_DB_ADMIN_USER REPORTING_DB_NAME REPORTING_DB_READER_USER N8N_DB_USER N8N_DB_NAME)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || {
    echo "FAIL: $name is missing or placeholder."; exit 1;
  }
done

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

policy_state="$("${compose[@]}" exec -T reporting-db psql -X -q -A -t   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
  SELECT provider_key || '|' || intent_enabled::int || '|' || summary_enabled::int
  FROM governance.get_ai_adapter_policy();
")"
[[ "$policy_state" =~ ^groq\|[01]\|[01]$ ]] || {
  echo "FAIL: AI adapter policy is invalid: $policy_state"; exit 1;
}
IFS='|' read -r _ live_intent_enabled live_summary_enabled <<< "$policy_state"

priv_state="$("${compose[@]}" exec -T reporting-db psql -X -q -A -t   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
  SELECT
    has_function_privilege('$REPORTING_DB_READER_USER','governance.get_ai_adapter_policy()','EXECUTE')::int
    || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','governance.ai_adapter_config','SELECT')::int;
")"
[[ "$priv_state" == "1|0" ]] || {
  echo "FAIL: AI policy least-privilege boundary is incorrect: $priv_state"; exit 1;
}

workflow_state="$("${compose[@]}" exec -T n8n-db psql -X -q -A -F '|'   -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
  SELECT id,active::int,(\"versionId\"=\"activeVersionId\")::int,jsonb_array_length(nodes::jsonb)
  FROM workflow_entity
  WHERE id IN ('REVINTV2AIADAPTER01','REVINTV2AGENTCORE01')
  ORDER BY id;
")"
printf '%s\n' "$workflow_state" | awk -F '|' '$1=="REVINTV2AIADAPTER01" && $2=="1" && $3=="1" && ($4+0)>=17 {ok=1} END{exit !ok}' || {
  echo "FAIL: live AI adapter workflow is not active/published with the required baseline nodes: $workflow_state"; exit 1;
}
printf '%s\n' "$workflow_state" | awk -F '|' '$1=="REVINTV2AGENTCORE01" && $2=="1" && $3=="1" && ($4+0)>=22 {ok=1} END{exit !ok}' || {
  echo "FAIL: live Agent Core workflow is not active/published with the AI integration baseline: $workflow_state"; exit 1;
}

python3 - <<'PY'
import json
from pathlib import Path
root=Path('.')
ai=json.loads((root/'workflows/runtime-templates/REVINT-V2-AI-01.json').read_text())[0]
core=json.loads((root/'workflows/runtime-templates/REVINT-V2-AGENT-01.json').read_text())[0]

assert len(ai['nodes']) == 17
assert not any(n['type']=='n8n-nodes-base.webhook' for n in ai['nodes'])
names={n['name'] for n in ai['nodes']}
required={
 'AI | Parse Reporting Intent','AI-PAR | Intent Schema','AI-MDL | Groq Intent Model',
 'AI | Generate Management Summary','AI-PAR | Management Summary Schema',
 'AI-MDL | Groq Summary Model'
}
assert required <= names

for name in ('AI-MDL | Groq Intent Model','AI-MDL | Groq Summary Model'):
    n=next(x for x in ai['nodes'] if x['name']==name)
    cred=n.get('credentials',{}).get('groqApi',{})
    assert cred.get('id') == 'REVINTGROQ001'
    assert not n.get('credentials',{}).get('postgres')

cn={n['name']:n for n in core['nodes']}
assert cn['AI | Run Governed Intent Adapter'].get('onError') == 'continueRegularOutput'
assert cn['AI | Run Management Summary Adapter'].get('onError') == 'continueRegularOutput'
assert 'REP | Build Presentation Artifact' in cn
assert core['connections']['CTX | Bind Report Service']['main'][0][0]['node']=='CTX | Prepare AI Intent Request'
assert core['connections']['CTX | Bind SSO Principal']['main'][0][0]['node']=='CTX | Prepare AI Intent Request'
print('PASS: AI adapter is internal, credential-isolated, fail-soft, and wired behind security.')
PY

if [[ "$live_intent_enabled" == "1" || "$live_summary_enabled" == "1" ]]; then
  credential_state="$("${compose[@]}" exec -T n8n-db psql -X -q -A -t     -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
      SELECT count(*) || '|' || count(*) FILTER (WHERE data NOT LIKE '{%')
      FROM credentials_entity WHERE id='REVINTGROQ001' AND type='groqApi';
    ")"
  [[ "$credential_state" == "1|1" ]] || {
    echo "FAIL: enabled AI adapter is missing encrypted Groq credential."; exit 1;
  }
fi

bash "$ROOT_DIR/scripts/verify-agent-core.sh"

echo "PASS: governed AI intelligence and presentation migration verification passed."

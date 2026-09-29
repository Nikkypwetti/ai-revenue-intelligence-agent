#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
source "$ENV_FILE"
set +a
compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

original="$("${compose[@]}" exec -T reporting-db psql -X -q -A -t   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
SELECT intent_enabled::int||'|'||summary_enabled::int||'|'||intent_model||'|'||summary_model
FROM governance.get_ai_adapter_policy();")"
IFS='|' read -r original_intent original_summary original_intent_model original_summary_model <<<"$original"

restore_policy() {
  intent=false
  summary=false
  [[ "$original_intent" == "1" ]] && intent=true
  [[ "$original_summary" == "1" ]] && summary=true
  "${compose[@]}" exec -T reporting-db psql -X -q     -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
UPDATE governance.ai_adapter_config
SET intent_enabled=$intent,summary_enabled=$summary,
    intent_model='$original_intent_model',summary_model='$original_summary_model',updated_at=now()
WHERE config_id=1;" >/dev/null 2>&1 || true
}
trap restore_policy EXIT

"${compose[@]}" exec -T reporting-db psql -X -q   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
UPDATE governance.ai_adapter_config
SET intent_enabled=true,summary_enabled=false,
    intent_model='revint-deliberately-unavailable-model',updated_at=now()
WHERE config_id=1;" >/dev/null

python3 - <<'PY'
import json, os, urllib.request
url=f"http://127.0.0.1:{os.environ.get('N8N_PORT','5681')}/webhook/revint/v2/report"
request=urllib.request.Request(
    url,
    data=json.dumps({"question":"How many open deals do we have this month?"}).encode(),
    headers={"Content-Type":"application/json","X-Revint-Report-Key":os.environ["REPORT_API_KEY"]},
    method="POST",
)
with urllib.request.urlopen(request,timeout=45) as response:
    body=json.loads(response.read().decode())
assert response.status==200
assert body.get("status")=="success"
assert (body.get("report") or {}).get("kpi_key")=="open_deals_count"
print("PASS: induced AI provider failure preserved deterministic governed reporting.")
PY


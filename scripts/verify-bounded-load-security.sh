#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
original="$("${compose[@]}" exec -T reporting-db psql -X -q -A -t   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
SELECT intent_enabled::int||'|'||summary_enabled::int||'|'||intent_model||'|'||summary_model
FROM governance.get_ai_adapter_policy();")"
IFS='|' read -r oi os om sm <<<"$original"

restore_policy() {
  intent=false; summary=false
  [[ "$oi" == "1" ]] && intent=true
  [[ "$os" == "1" ]] && summary=true
  "${compose[@]}" exec -T reporting-db psql -X -q     -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
UPDATE governance.ai_adapter_config
SET intent_enabled=$intent,summary_enabled=$summary,
    intent_model='$om',summary_model='$sm',updated_at=now()
WHERE config_id=1;" >/dev/null 2>&1 || true
}
trap restore_policy EXIT

"${compose[@]}" exec -T reporting-db psql -X -q   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
UPDATE governance.ai_adapter_config
SET intent_enabled=false,summary_enabled=false,updated_at=now()
WHERE config_id=1;" >/dev/null

python3 - <<'PY'
import concurrent.futures,json,os,time,urllib.request,urllib.error,socket
url=f"http://127.0.0.1:{os.environ.get('N8N_PORT','5681')}/webhook/revint/v2/report"
key=os.environ['REPORT_API_KEY']
payload=json.dumps({"structured_intent":{
  "kpi_key":"open_deals_count","period_key":"this_month","mode":"metric_report",
  "dimensions":[],"filters":{}
}}).encode()

def call(auth=True):
    headers={"Content-Type":"application/json"}
    if auth: headers["X-Revint-Report-Key"]=key
    req=urllib.request.Request(url,data=payload,headers=headers,method="POST")
    started=time.monotonic()
    try:
        with urllib.request.urlopen(req,timeout=30) as response:
            status=response.status; response.read()
    except urllib.error.HTTPError as exc:
        status=exc.code; exc.read()
    except (TimeoutError,socket.timeout):
        status=598
    return status,time.monotonic()-started

assert [call(False)[0] for _ in range(4)] == [403,403,403,403]

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
    results=list(executor.map(lambda _:call(True),range(12)))

statuses=[status for status,_ in results]
assert 598 not in statuses, statuses
assert all(status in (200,429) for status in statuses),statuses
assert statuses.count(200)>=8,statuses
latencies=sorted(latency for status,latency in results if status==200)
p95=latencies[max(0,int(len(latencies)*0.95)-1)]
print(f"PASS: deterministic bounded load/auth test success={statuses.count(200)} rate_limited={statuses.count(429)} p95={p95:.3f}s")
PY


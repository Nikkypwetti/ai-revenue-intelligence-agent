#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
TOTAL="${LOAD_TEST_TOTAL:-40}"
CONCURRENCY="${LOAD_TEST_CONCURRENCY:-4}"
CONFIRM=""

fail() { echo "FAIL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --total) TOTAL="${2:-}"; shift 2 ;;
    --concurrency) CONCURRENCY="${2:-}"; shift 2 ;;
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: bash scripts/load-test-report-api.sh [--total N] [--concurrency N] --confirm REVINT_LOCAL_LOAD_TEST"
      exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$CONFIRM" == "REVINT_LOCAL_LOAD_TEST" ]] || fail "confirmation token is missing."
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ "$TOTAL" =~ ^[0-9]+$ && "$CONCURRENCY" =~ ^[0-9]+$ ]] || fail "total/concurrency must be positive integers."
(( TOTAL >= 1 && TOTAL <= 200 )) || fail "total must be between 1 and 200."
(( CONCURRENCY >= 1 && CONCURRENCY <= 20 )) || fail "concurrency must be between 1 and 20."

set -a
source "$ENV_FILE"
set +a

: "${REPORT_API_KEY:?Missing REPORT_API_KEY}"
port="${N8N_PORT:-5681}"

python3 - "$TOTAL" "$CONCURRENCY" "$port" <<'PY'
import concurrent.futures, json, os, statistics, sys, time, urllib.request, urllib.error

total=int(sys.argv[1]); concurrency=int(sys.argv[2]); port=sys.argv[3]
url=f"http://127.0.0.1:{port}/webhook/revint/v2/report"
key=os.environ["REPORT_API_KEY"]
payload=json.dumps({
  "structured_intent":{
    "kpi_key":"open_pipeline",
    "period_key":"this_month",
    "mode":"metric_report",
    "dimensions":[],
    "filters":{}
  }
}).encode()

def one(_):
    req=urllib.request.Request(url,data=payload,headers={"Content-Type":"application/json","X-Revint-Report-Key":key},method="POST")
    start=time.perf_counter()
    try:
        with urllib.request.urlopen(req,timeout=30) as r:
            status=r.status
            raw=r.read()
            body=json.loads(raw.decode())
    except urllib.error.HTTPError as e:
        status=e.code
        body={}
        e.read()
    except Exception:
        return 0,time.perf_counter()-start,False
    ok=status==200 and body.get("status")=="success"
    return status,time.perf_counter()-start,ok

with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as ex:
    rows=list(ex.map(one,range(total)))

statuses={}
latencies=[]
success=0
for status,latency,ok in rows:
    statuses[status]=statuses.get(status,0)+1
    latencies.append(latency)
    success += int(ok)

latencies_ms=[x*1000 for x in latencies]
ordered=sorted(latencies_ms)
p95=ordered[max(0,min(len(ordered)-1,int(round(0.95*(len(ordered)-1)))))]
success_rate=success/total
print("TOTAL="+str(total))
print("CONCURRENCY="+str(concurrency))
print("SUCCESS="+str(success))
print("SUCCESS_RATE="+f"{success_rate:.3f}")
print("HTTP_STATUS_COUNTS="+json.dumps(statuses,sort_keys=True))
print("LATENCY_MS_MEAN="+f"{statistics.mean(latencies_ms):.1f}")
print("LATENCY_MS_P95="+f"{p95:.1f}")

if any(code >= 500 for code in statuses if code):
    raise SystemExit("FAIL: report API returned 5xx during bounded load test.")
if success_rate < 0.95:
    raise SystemExit("FAIL: success rate below 95% during bounded load test.")
print("PASS: bounded local report API load test passed.")
PY

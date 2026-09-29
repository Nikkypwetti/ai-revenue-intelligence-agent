#!/usr/bin/env python3
import argparse
import concurrent.futures
import json
import os
import statistics
import time
import urllib.error
import urllib.request

def request(url, key, payload, timeout):
    data=json.dumps(payload).encode()
    req=urllib.request.Request(
        url, data=data, method="POST",
        headers={"Content-Type":"application/json","X-Revint-Report-Key":key}
    )
    start=time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            body=res.read()
            status=res.status
    except urllib.error.HTTPError as exc:
        body=exc.read()
        status=exc.code
    except Exception as exc:
        return {"status":0,"latency":time.perf_counter()-start,"error":type(exc).__name__}
    latency=time.perf_counter()-start
    try:
        parsed=json.loads(body.decode())
        app_status=parsed.get("status")
    except Exception:
        app_status=None
    return {"status":status,"latency":latency,"app_status":app_status}

def percentile(values,p):
    if not values: return 0.0
    ordered=sorted(values)
    idx=max(0,min(len(ordered)-1,round((len(ordered)-1)*p)))
    return ordered[idx]

def main():
    ap=argparse.ArgumentParser(description="Bounded Agent V2 report API load test.")
    ap.add_argument("--url",default=os.getenv("REVINT_REPORT_URL","http://127.0.0.1:5681/webhook/revint/v2/report"))
    ap.add_argument("--requests",type=int,default=25)
    ap.add_argument("--concurrency",type=int,default=5)
    ap.add_argument("--timeout",type=float,default=20.0)
    ap.add_argument("--use-ai",action="store_true",help="Use natural-language input. Default structured intent avoids model cost.")
    args=ap.parse_args()
    if not 1 <= args.requests <= 500: ap.error("--requests must be 1..500")
    if not 1 <= args.concurrency <= 25: ap.error("--concurrency must be 1..25")

    key=os.getenv("REPORT_API_KEY")
    if not key or key.startswith("CHANGE_ME"):
        raise SystemExit("FAIL: REPORT_API_KEY is missing.")

    payload=(
        {"question":"How many open deals do we have this month?"}
        if args.use_ai else
        {"structured_intent":{"kpi_key":"open_deals_count","period_key":"this_month","mode":"metric_report","dimensions":[],"filters":{}}}
    )

    started=time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        results=list(ex.map(lambda _:request(args.url,key,payload,args.timeout),range(args.requests)))
    wall=time.perf_counter()-started

    lat=[x["latency"] for x in results]
    ok=[x for x in results if x["status"]==200 and x.get("app_status")=="success"]
    status_counts={}
    for x in results: status_counts[x["status"]]=status_counts.get(x["status"],0)+1

    report={
        "requests":args.requests,
        "concurrency":args.concurrency,
        "use_ai":args.use_ai,
        "success_count":len(ok),
        "error_count":args.requests-len(ok),
        "status_counts":status_counts,
        "wall_seconds":round(wall,3),
        "requests_per_second":round(args.requests/wall,3) if wall else 0,
        "latency_ms":{
            "min":round(min(lat)*1000,2),
            "p50":round(percentile(lat,.50)*1000,2),
            "p95":round(percentile(lat,.95)*1000,2),
            "max":round(max(lat)*1000,2),
            "mean":round(statistics.mean(lat)*1000,2)
        }
    }
    print(json.dumps(report,indent=2,sort_keys=True))
    if len(ok) != args.requests:
        raise SystemExit(1)

if __name__=="__main__":
    main()

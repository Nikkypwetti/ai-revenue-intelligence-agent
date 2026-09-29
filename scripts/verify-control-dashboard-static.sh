#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-CONTROL-01.json"
DEPLOY="$ROOT_DIR/scripts/deploy-control-dashboard.sh"
INGRESS="$ROOT_DIR/deploy/nginx/revint.conf.template"

python3 - "$WORKFLOW" <<'PY'
import json,re,sys
wf=json.load(open(sys.argv[1]))
assert wf["id"]=="REVINTV2CONTROL01"
assert wf["name"]=="REVINT-V2-CONTROL-01 | Local Control Dashboard"
assert wf["active"] is False
assert wf["settings"]["errorWorkflow"]=="REVINTV2SYSERROR01"
assert wf["settings"]["availableInMCP"] is False
assert len(wf["nodes"])==4

nodes={n["name"]:n for n in wf["nodes"]}
required={
  "INT | Local Control Dashboard",
  "DB | Load Governed Control Snapshot",
  "REP | Build Control Center",
  "DEL | Return Control Center",
}
assert required == set(nodes)

hook=nodes["INT | Local Control Dashboard"]
assert hook["type"]=="n8n-nodes-base.webhook"
assert hook["parameters"]["httpMethod"]=="GET"
assert hook["parameters"]["path"]=="revint/v2/control"
assert hook["parameters"]["responseMode"]=="responseNode"
assert hook["parameters"]["authentication"]=="none"

db=nodes["DB | Load Governed Control Snapshot"]
assert db["type"]=="n8n-nodes-base.postgres"
assert db["credentials"]["postgres"]["id"]=="REVINTPGREPORTRO001"
assert db["credentials"]["postgres"]["name"]=="REVINT | Reporting RO"
assert db.get("retryOnFail") is True and db.get("maxTries")==3
query=db["parameters"]["query"]
for token in (
  "governance.business_config",
  "governance.kpi_catalog",
  "governance.connector_registry",
  "observability.runtime_status",
  "observability.component_status",
  "observability.alert_ready",
):
    assert token in query, token
assert re.match(r"^\s*SELECT\b",query,re.I)
assert not re.search(r"\b(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP|CREATE)\b",query,re.I)

builder=nodes["REP | Build Control Center"]["parameters"]["jsCode"]
for token in ("Read-only control surface","CRM & Source Connectors","Reliability & Observability","Active Alerts","replace(/[&<>"):
    assert token in builder, token
assert "credentials" not in builder.lower()
assert "audit.agent_events" not in builder

resp=nodes["DEL | Return Control Center"]
headers={x["name"]:x["value"] for x in resp["parameters"]["options"]["responseHeaders"]["entries"]}
assert headers["Cache-Control"]=="no-store"
assert "default-src 'none'" in headers["Content-Security-Policy"]
assert "frame-ancestors 'none'" in headers["Content-Security-Policy"]

print("PASS: control dashboard is GET-only, read-only and uses Reporting RO.")
print("PASS: dashboard renders only bounded governance/observability surfaces.")
print("PASS: dashboard response applies restrictive browser security headers.")
PY

bash -n "$DEPLOY"
grep -q 'REVINT_CONTROL_DASHBOARD' "$DEPLOY"
grep -q 'REVINTV2CONTROL01' "$DEPLOY"
grep -q 'REVINTPGREPORTRO001' "$DEPLOY"
grep -q 'stop n8n' "$DEPLOY"

if grep -q 'revint/v2/control' "$INGRESS"; then
  echo "FAIL: local control dashboard path must not be routed by public ingress."
  exit 1
fi

if bash "$DEPLOY" --confirm WRONG_TOKEN >/tmp/revint-control-guard.out 2>&1; then
  echo "FAIL: invalid control dashboard activation token was accepted."
  exit 1
fi
grep -q 'control dashboard confirmation token is missing or incorrect' /tmp/revint-control-guard.out
rm -f /tmp/revint-control-guard.out

echo "PASS: control dashboard deployment remains explicit and local-only."
echo "PASS: control dashboard static verification passed."

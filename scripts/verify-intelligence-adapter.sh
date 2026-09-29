#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AGENT-01.json"

python3 - "$WORKFLOW" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p)); w=d[0] if isinstance(d,list) else d
names={n.get("name") for n in w.get("nodes",[])}
required={
 "VAL | Use LLM Intent?",
 "AI | Prepare Groq Intent Request",
 "AI | Groq Interpret Intent",
 "VAL | Normalize Groq Intent",
 "CTX | Interpret Report Request",
 "DB | Execute Governed Metric",
}
missing=sorted(required-names)
if missing: raise SystemExit("FAIL: missing intelligence nodes: "+", ".join(missing))
PY
python3 - "$WORKFLOW" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); w=d[0] if isinstance(d,list) else d
c=w["connections"]
assert c["CTX | Bind Report Service"]["main"][0][0]["node"]=="VAL | Use LLM Intent?"
assert c["CTX | Bind SSO Principal"]["main"][0][0]["node"]=="VAL | Use LLM Intent?"
branches=c["VAL | Use LLM Intent?"]["main"]
assert branches[0][0]["node"]=="AI | Prepare Groq Intent Request"
assert branches[1][0]["node"]=="CTX | Interpret Report Request"
assert c["VAL | Normalize Groq Intent"]["main"][0][0]["node"]=="CTX | Interpret Report Request"
http=next(n for n in w["nodes"] if n["name"]=="AI | Groq Interpret Intent")
assert http["parameters"]["authentication"]=="genericCredentialType"
assert http["parameters"]["genericAuthType"]=="httpHeaderAuth"
cred=http["credentials"]["httpHeaderAuth"]
assert cred["id"]=="REVINTGROQAI001"
assert http.get("onError")=="continueRegularOutput"
print("PASS: optional Groq intent path rejoins deterministic Agent V2 validation.")
PY
grep -q '^REVINT_LLM_ENABLED=false$' "$ROOT_DIR/deploy/.env.example"
grep -q '^GROQ_API_KEY=CHANGE_ME_' "$ROOT_DIR/deploy/.env.example"
grep -q 'REVINT_LLM_ENABLED:' "$ROOT_DIR/deploy/docker-compose.yml"
if grep -q 'GROQ_API_KEY:' "$ROOT_DIR/deploy/docker-compose.yml"; then
  echo "FAIL: raw Groq secret must not be injected into the long-running n8n service."
  exit 1
fi

if grep -Eqi 'gsk_[A-Za-z0-9_-]{10,}|Bearer[[:space:]]+[A-Za-z0-9_-]{16,}' "$WORKFLOW"; then
  echo "FAIL: secret-like Groq credential found in workflow JSON."
  exit 1
fi

grep -q 'REVINTGROQAI001' "$ROOT_DIR/scripts/import-groq-runtime-credential.sh"
grep -q 'import-groq-runtime-credential.sh' "$ROOT_DIR/scripts/deploy-agent-core.sh"

bash -n "$ROOT_DIR/scripts/import-groq-runtime-credential.sh" "$ROOT_DIR/scripts/deploy-agent-core.sh"
python3 -m json.tool "$WORKFLOW" >/dev/null

echo "PASS: Groq credential remains encrypted and outside workflow JSON."
echo "PASS: LLM adapter is safe-disabled by default."
echo "PASS: reusable Agent V2 intelligence-adapter verification passed."

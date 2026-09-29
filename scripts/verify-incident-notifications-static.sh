#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-INCIDENT-01.json"
SYS_WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SYS-01.json"
MIGRATION="$ROOT_DIR/database/migrations/017_incident_notifications.sql"
SEED="$ROOT_DIR/database/seeds/010_incident_notification_reliability.sql"
ENV_EXAMPLE="$ROOT_DIR/deploy/.env.example"
DEPLOY="$ROOT_DIR/scripts/deploy-incident-notifications.sh"
IMPORT_CRED="$ROOT_DIR/scripts/import-incident-slack-credential.sh"

python3 - "$WORKFLOW" "$SYS_WORKFLOW" "$MIGRATION" "$SEED" <<'PY'
import json,re,sys
wf=json.load(open(sys.argv[1]))[0]
syswf=json.load(open(sys.argv[2]))[0]
migration=open(sys.argv[3]).read()
seed=open(sys.argv[4]).read()

assert wf["id"]=="REVINTV2INCIDENT01"
assert wf["active"] is False
assert wf["settings"]["errorWorkflow"]=="REVINTV2SYSERROR01"
assert len(wf["nodes"])==6
assert not any(n["type"]=="n8n-nodes-base.webhook" for n in wf["nodes"])

nodes={n["name"]:n for n in wf["nodes"]}
slack=nodes["DEL | Send Incident Slack Alert"]
assert slack["credentials"]["slackApi"]["id"]=="REVINTSLACKINCIDENT001"
assert slack["retryOnFail"] is True and slack["maxTries"]==2
query=nodes["DB | Load Pending Incident Alerts"]["parameters"]["query"]
assert "observability.get_pending_incident_notifications()" in query
audit=nodes["AUD | Record Incident Notification"]["parameters"]["query"]
assert "record_incident_notification_success" in audit

payload=nodes["REP | Build Incident Slack Payload"]["parameters"]["jsCode"]
assert "destination_id" in payload
assert "raw" not in payload.lower()
assert "stack" not in payload.lower()

syscode=next(n["parameters"]["jsCode"] for n in syswf["nodes"] if n["name"]=="SYS | Normalize Terminal Failure")
assert "REVINTV2INCIDENT01: 'incident_notifications'" in syscode

for token in (
 "incident_notification_config",
 "incident_notification_state",
 "get_pending_incident_notifications",
 "record_incident_notification_success",
 "cooldown_seconds",
):
 assert token in migration, token
assert "'incident_notifications'" in seed
assert "REVINTV2INCIDENT01" in seed
assert "false" in seed

serialized=json.dumps(wf)
for pattern in (r"Bearer\s+[A-Za-z0-9._-]{12,}",r"xox[baprs]-[A-Za-z0-9-]+"):
 assert not re.search(pattern,serialized,re.I)

print("PASS: incident workflow is internal, dedicated-credential and disabled by default.")
print("PASS: pending-alert selection uses governed severity/cooldown/deduplication state.")
print("PASS: incident delivery failures route through the reliability/dead-letter core.")
PY

for f in  "$ROOT_DIR/scripts/import-incident-slack-credential.sh"  "$ROOT_DIR/scripts/init-incident-notifications.sh"  "$ROOT_DIR/scripts/deploy-incident-notifications.sh"  "$ROOT_DIR/scripts/verify-incident-notifications-static.sh"; do
  bash -n "$f"
done

grep -q '^INCIDENT_SLACK_ENABLED=false$' "$ENV_EXAMPLE"
grep -q '^INCIDENT_MIN_SEVERITY=warning$' "$ENV_EXAMPLE"
grep -q 'REVINTSLACKINCIDENT001' "$IMPORT_CRED"
grep -q 'enabled=false' "$DEPLOY"
grep -q 'enabled=true' "$DEPLOY"
grep -q 'stop n8n' "$DEPLOY"

if bash "$DEPLOY" --confirm WRONG >/tmp/revint-incident-guard.out 2>&1; then
  echo "FAIL: invalid incident confirmation was accepted."
  exit 1
fi
grep -q 'confirmation token is missing or incorrect' /tmp/revint-incident-guard.out
rm -f /tmp/revint-incident-guard.out

echo "PASS: incident notification static verification passed."

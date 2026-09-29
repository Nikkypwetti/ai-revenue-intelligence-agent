#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AIR="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AIRTABLE-01.json"
EMAIL="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-EMAIL-01.json"
ENV="$ROOT_DIR/deploy/.env.example"
EMAIL_RELIABILITY="$ROOT_DIR/database/seeds/012_email_delivery_reliability.sql"

python3 - "$AIR" "$EMAIL" <<'PY'
import json,re,sys
air=json.load(open(sys.argv[1]))[0]
email=json.load(open(sys.argv[2]))[0]

assert air["id"]=="REVINTV2AIRTABLE01" and air["active"] is False
assert len(air["nodes"])==10
assert air["settings"]["errorWorkflow"]=="REVINTV2SYSERROR01"
an={n["name"]:n for n in air["nodes"]}
src=an["SRC | Fetch Airtable Opportunities"]
assert src["type"]=="n8n-nodes-base.airtable"
assert src["parameters"]["operation"]=="search"
assert src["credentials"]["airtableTokenApi"]["id"]=="REVINTAIRTABLE001"
assert src["credentials"]["airtableTokenApi"]["name"]=="REVINT | Airtable Opportunities RO"
assert src["parameters"]["base"]["value"]=="={{ $env.AIRTABLE_BASE_ID }}"
assert src["parameters"]["table"]["value"]=="={{ $env.AIRTABLE_TABLE_ID }}"
assert "AIRTABLE_LAST_MODIFIED_FIELD" in an["CTX | Build Airtable Search"]["parameters"]["jsCode"]
assert "ingest_deal_batch_from_source" in an["DB | Ingest Airtable Batch"]["parameters"]["query"]
assert "record_connector_sync_completion" in an["AUD | Complete Airtable Sync"]["parameters"]["query"]
for n in air["nodes"]:
    if n["type"]=="n8n-nodes-base.airtable":
        assert n["parameters"].get("operation") not in {"create","update","upsert","deleteRecord"}
assert not any(n["type"]=="n8n-nodes-base.webhook" for n in air["nodes"])

assert email["id"]=="REVINTV2EMAIL01" and email["active"] is False
assert len(email["nodes"])==14
assert email["settings"]["errorWorkflow"]=="REVINTV2SYSERROR01"
en={n["name"]:n for n in email["nodes"]}
assert en["INT | Governed Email Delivery Adapter"]["type"]=="n8n-nodes-base.executeWorkflowTrigger"
assert not any(n["type"]=="n8n-nodes-base.webhook" for n in email["nodes"])
assert "resolve_email_delivery_request" in en["DB | Resolve Email Authorization"]["parameters"]["query"]
gmail=en["DEL | Send Gmail Report"]
assert gmail["type"]=="n8n-nodes-base.gmail"
assert gmail["parameters"]["resource"]=="message"
assert gmail["parameters"]["operation"]=="send"
assert gmail["credentials"]["gmailOAuth2"]["id"]=="REVINTGMAILREPORT001"
assert gmail["parameters"]["sendTo"]=="={{ $json.email_payload.send_to }}"
build=en["REP | Build Email Report Payload"]["parameters"]["jsCode"]
assert "email_authorization" in build
assert "recipient_email" in build
assert "delivery_request" in build
serialized=json.dumps(email)
for pat in (r"Bearer\s+[A-Za-z0-9._-]{12,}",r"access_token",r"refresh_token",r"client_secret"):
    assert not re.search(pat,serialized,re.I)

print("PASS: Airtable workflow is internal/read-only and uses the governed canonical ingestion boundary.")
print("PASS: Gmail workflow is internal, role-governed and resolves recipient server-side.")
PY

for f in  "$ROOT_DIR/scripts/import-airtable-runtime-credential.sh"  "$ROOT_DIR/scripts/init-airtable-connector.sh"  "$ROOT_DIR/scripts/deploy-airtable-connector.sh"  "$ROOT_DIR/scripts/init-email-delivery.sh"  "$ROOT_DIR/scripts/deploy-email-delivery.sh"; do
  bash -n "$f"
done

grep -q '^AIRTABLE_SYNC_ENABLED=false$' "$ENV"
grep -q '^EMAIL_REPORT_ENABLED=false$' "$ENV"
grep -q 'REVINTAIRTABLE001' "$ROOT_DIR/scripts/deploy-airtable-connector.sh"
grep -q "name='REVINT | Gmail Reports'" "$ROOT_DIR/scripts/deploy-email-delivery.sh"
grep -q 'gmail_credential_id' "$ROOT_DIR/scripts/deploy-email-delivery.sh"
grep -q 'tmp_workflow' "$ROOT_DIR/scripts/deploy-email-delivery.sh"
grep -q "'email_delivery'" "$EMAIL_RELIABILITY"
grep -q 'REVINTV2EMAIL01' "$EMAIL_RELIABILITY"
grep -q '012_email_delivery_reliability.sql' "$ROOT_DIR/scripts/init-email-delivery.sh"
grep -q 'CHANGE_ME_' "$ROOT_DIR/config/first-client.connectors.example.json"

if bash "$ROOT_DIR/scripts/deploy-airtable-connector.sh" --confirm WRONG >/tmp/revint-air-guard.out 2>&1; then
  echo "FAIL: invalid Airtable activation token was accepted."; exit 1
fi
grep -q 'activation confirmation token is missing or incorrect' /tmp/revint-air-guard.out
rm -f /tmp/revint-air-guard.out

if bash "$ROOT_DIR/scripts/deploy-email-delivery.sh" --confirm WRONG >/tmp/revint-email-guard.out 2>&1; then
  echo "FAIL: invalid email activation token was accepted."; exit 1
fi
grep -q 'confirmation token is missing or incorrect' /tmp/revint-email-guard.out
rm -f /tmp/revint-email-guard.out

echo "PASS: Airtable + email adapter static verification passed."

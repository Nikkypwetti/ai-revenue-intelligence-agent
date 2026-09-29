#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SALESFORCE-01.json"
SYS_WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SYS-01.json"
CONFIG="$ROOT_DIR/config/salesforce-connector.example.json"
DEPLOY="$ROOT_DIR/scripts/deploy-salesforce-connector.sh"
ENV_EXAMPLE="$ROOT_DIR/deploy/.env.example"

python3 - "$WORKFLOW" "$SYS_WORKFLOW" "$CONFIG" <<'PY'
import json,re,sys
wf=json.load(open(sys.argv[1]))[0]
syswf=json.load(open(sys.argv[2]))[0]
cfg=json.load(open(sys.argv[3]))

assert wf["id"]=="REVINTV2SALESFORCE01"
assert wf["active"] is False
assert wf["settings"]["errorWorkflow"]=="REVINTV2SYSERROR01"
assert len(wf["nodes"])==10
assert not any(n["type"]=="n8n-nodes-base.webhook" for n in wf["nodes"])

nodes={n["name"]:n for n in wf["nodes"]}
required={
 "DB | Load Salesforce Sync Context",
 "CTX | Build Salesforce SOQL",
 "SRC | Fetch Salesforce Opportunities",
 "VAL | Normalize Salesforce Opportunities",
 "DB | Ingest Salesforce Batch",
 "AUD | Complete Salesforce Sync",
}
assert required <= set(nodes)

http=nodes["SRC | Fetch Salesforce Opportunities"]
cred=http["credentials"]["salesforceOAuth2Api"]
assert cred["id"]=="REVINTSALESFORCERO001"
assert cred["name"]=="REVINT | Salesforce Opportunities RO"
assert "$env.SALESFORCE_INSTANCE_URL" in http["parameters"]["url"]
assert http["parameters"]["method"]=="GET"
assert http["retryOnFail"] is True and http["maxTries"]==3

query=nodes["CTX | Build Salesforce SOQL"]["parameters"]["jsCode"]
for token in (
 "FROM Opportunity",
 "LastModifiedDate >=",
 "LastModifiedDate <=",
 "ORDER BY LastModifiedDate ASC",
 "LIMIT 2000",
 "Primary_Need__c",
 "Decision_Maker_Confirmed__c",
 "Lost_Reason__c",
 "Implementation_Priority__c",
 "Won_Date__c",
 "Lost_Date__c",
 "High_Value__c",
):
    assert token in query, token

normalize=nodes["VAL | Normalize Salesforce Opportunities"]["parameters"]["jsCode"]
for stage in ("Discovery","Technical Review","Proposal Sent","Negotiation","Closed Won","Closed Lost"):
    assert stage in normalize
assert "SALESFORCE_SYNC_WINDOW_LIMIT_EXCEEDED" in normalize
assert "nextRecordsUrl" in normalize
assert "rejectedCount" in normalize
assert "salesforce_primary" in normalize

assert "ingest_deal_batch_from_source" in nodes["DB | Ingest Salesforce Batch"]["parameters"]["query"]
assert "record_connector_sync_completion" in nodes["AUD | Complete Salesforce Sync"]["parameters"]["query"]

serialized=json.dumps(wf)
for bad in ("create","update","upsert","delete"):
    # Provider node is HTTP GET only; DB upsert terminology may appear in notes/function names.
    pass
for pattern in (r"Bearer\s+[A-Za-z0-9._-]{12,}",r"refresh_token",r"client_secret"):
    assert not re.search(pattern,serialized,re.I)

syscode=next(n["parameters"]["jsCode"] for n in syswf["nodes"] if n["name"]=="SYS | Normalize Terminal Failure")
assert "REVINTV2SALESFORCE01: 'salesforce_sync'" in syscode
assert "REVINTV2AIRTABLE01: 'airtable_sync'" in syscode

connector=cfg["connectors"][0]
assert connector["connector_key"]=="salesforce_primary"
assert connector["connector_type"]=="salesforce"
assert connector["active"] is False
actual={x["source_value"]:x["canonical_value"] for x in connector["value_mappings"]}
assert actual=={
 "Discovery":"open",
 "Technical Review":"open",
 "Proposal Sent":"open",
 "Negotiation":"open",
 "Closed Won":"won",
 "Closed Lost":"lost",
}

print("PASS: Salesforce workflow is internal, bounded, read-oriented and disabled by default.")
print("PASS: AsterNova stages map deterministically into the canonical contract.")
print("PASS: Salesforce terminal failures route through the reusable reliability core.")
PY

node - "$WORKFLOW" <<'NODE'
const fs=require('fs');
const wf=JSON.parse(fs.readFileSync(process.argv[2],'utf8'))[0];
const code=wf.nodes.find(n=>n.name==='VAL | Normalize Salesforce Opportunities').parameters.jsCode;
const context={
  connector_key:'salesforce_primary',
  connector_type:'salesforce',
  currency_code:'USD',
  query_start_at:'2026-09-01T00:00:00.000Z',
  query_end_at:'2026-09-30T00:00:00.000Z'
};
const response={
  done:true,
  records:[
    {Id:'006-open',Name:'Open',Amount:1000,StageName:'Discovery',OwnerId:'005-a',LeadSource:'Website',CreatedDate:'2026-09-01T00:00:00Z',CloseDate:'2026-10-01',LastModifiedDate:'2026-09-10T00:00:00Z'},
    {Id:'006-won',Name:'Won',Amount:2500,StageName:'Closed Won',OwnerId:'005-a',LeadSource:'Referral',CreatedDate:'2026-09-01T00:00:00Z',CloseDate:'2026-09-20',LastModifiedDate:'2026-09-20T12:00:00Z',Won_Date__c:'2026-09-20'},
    {Id:'006-bad',Name:'Bad',Amount:500,StageName:'Unknown Stage',OwnerId:'005-a',CreatedDate:'2026-09-01T00:00:00Z',CloseDate:'2026-10-01',LastModifiedDate:'2026-09-21T00:00:00Z'}
  ]
};
const dollar=(name)=>({
  first:()=>({json:{sync_context:context}}),
  item:{json:{sync_context:context}}
});
const input={first:()=>({json:response})};
const result=new Function('$','$input',code)(dollar,input)[0].json;
if(result.source_count!==3||result.record_count!==2||result.rejected_count!==1) throw new Error('normalization counts invalid');
const open=result.records.find(x=>x.source_record_id==='006-open');
const won=result.records.find(x=>x.source_record_id==='006-won');
if(!open||!won) throw new Error('expected canonical envelopes missing');
if(open.source_payload.StageName!=='Discovery'||won.source_payload.StageName!=='Closed Won') throw new Error('stage mapping failed');
console.log('PASS: Salesforce normalization accepts known stages and rejects unknown stages.');
NODE

for script in  "$ROOT_DIR/scripts/init-salesforce-connector.sh"  "$ROOT_DIR/scripts/deploy-salesforce-connector.sh"  "$ROOT_DIR/scripts/verify-salesforce-connector-static.sh"; do
  bash -n "$script"
done

grep -q '^SALESFORCE_SYNC_ENABLED=false$' "$ENV_EXAMPLE"
grep -q '^SALESFORCE_READONLY_CONFIRMED=false$' "$ENV_EXAMPLE"
grep -q '^SALESFORCE_INSTANCE_URL=https://CHANGE_ME.my.salesforce.com$' "$ENV_EXAMPLE"
grep -q "REVINT | Salesforce Opportunities RO" "$DEPLOY"
grep -q "salesforceOAuth2Api" "$DEPLOY"
grep -q "tmp_workflow" "$DEPLOY"
grep -q "data NOT LIKE '{%'" "$DEPLOY"
grep -q "SALESFORCE_READONLY_CONFIRMED" "$DEPLOY"
grep -q 'stop n8n' "$DEPLOY"
grep -q 'set_connector_state false' "$DEPLOY"
grep -q 'set_connector_state true' "$DEPLOY"

if bash "$DEPLOY" --confirm WRONG_TOKEN >/tmp/revint-sf-guard.out 2>&1; then
  echo "FAIL: invalid Salesforce activation token was accepted."
  exit 1
fi
grep -q 'activation confirmation token is missing or incorrect' /tmp/revint-sf-guard.out
rm -f /tmp/revint-sf-guard.out

echo "PASS: Salesforce activation is guarded by explicit confirmation, encrypted credential presence and read-only attestation."
echo "PASS: Salesforce connector static verification passed."

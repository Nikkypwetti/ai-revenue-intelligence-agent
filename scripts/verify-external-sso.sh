#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
ENDPOINT="http://127.0.0.1:${N8N_PORT:-5681}/webhook/revint/v2/report-sso"
CERT="$ROOT_DIR/deploy/tls/tls.crt"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ -f "$CERT" ]] || fail "TLS certificate is missing."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  REPORTING_DB_ADMIN_USER REPORTING_DB_NAME
  REPORTING_DB_READER_USER REPORTING_DB_READER_PASSWORD
  N8N_DB_USER N8N_DB_NAME SSO_INTERNAL_API_KEY
  OAUTH2_PROXY_IMAGE PUBLIC_DOMAIN INGRESS_HTTPS_PORT
)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || fail "$name is missing or uses a placeholder."
done

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

psql_admin() {
  "${compose[@]}" exec -T reporting-db     psql -X -q -A -t -v ON_ERROR_STOP=1     -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" "$@"
}

psql_n8n() {
  "${compose[@]}" exec -T n8n-db     psql -X -q -A -t -v ON_ERROR_STOP=1     -U "$N8N_DB_USER" -d "$N8N_DB_NAME" "$@"
}

cleanup() {
  psql_admin -c "
    DELETE FROM audit.agent_events
    WHERE stage='agent_core'
      AND payload->>'principal_key' LIKE 'verify-sso-%';

    DELETE FROM reporting.deals
    WHERE source_record_id LIKE 'sso-verify-%';

    DELETE FROM governance.role_assignment
    WHERE principal_key LIKE 'verify-sso-%';

    DELETE FROM governance.department_membership
    WHERE principal_key LIKE 'verify-sso-%';

    DELETE FROM governance.principal_registry
    WHERE principal_key LIKE 'verify-sso-%';
  " >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

permission_state="$(psql_admin -c "
  SELECT
    has_function_privilege(
      'revint_reporting_ro',
      'governance.resolve_external_principal(text,text)',
      'EXECUTE'
    )::int || '|' ||
    has_table_privilege(
      'revint_reporting_ro',
      'governance.principal_registry',
      'SELECT'
    )::int;
")"
[[ "$permission_state" == "1|0" ]] ||   fail "SSO principal resolver privilege boundary is incorrect."

credential_state="$(psql_n8n -c "
  SELECT count(*) || '|' ||
         count(*) FILTER (WHERE data NOT LIKE '{%')
  FROM credentials_entity
  WHERE id='REVINTSSOINTERNAL001';
")"
[[ "$credential_state" == "1|1" ]] ||   fail "SSO internal n8n credential is missing or not encrypted."

workflow_active="$(psql_n8n -c "
  SELECT active::int
  FROM workflow_entity
  WHERE id='REVINTV2AGENTCORE01';
")"
[[ "$workflow_active" == "1" ]] || fail "Agent workflow is not active."

workflow_contract="$(psql_n8n <<'SQL'
SELECT
  count(*) FILTER (
    WHERE n->>'name'='INT | SSO Report Request'
      AND n->'credentials'->'httpHeaderAuth'->>'id'='REVINTSSOINTERNAL001'
  ) || '|' ||
  count(*) FILTER (
    WHERE n->>'name'='DB | Resolve SSO Principal'
      AND n->'credentials'->'postgres'->>'id'='REVINTPGREPORTRO001'
  ) || '|' ||
  count(*) FILTER (
    WHERE n->>'name'='CTX | Bind SSO Principal'
      AND (n->'parameters'->>'jsCode') LIKE '%principal_key: resolvedPrincipal%'
  )
FROM workflow_entity w
CROSS JOIN LATERAL json_array_elements(w.nodes) n
WHERE w.id='REVINTV2AGENTCORE01';
SQL
)"
[[ "$workflow_contract" == "1|1|1" ]] ||   fail "Agent workflow SSO identity-binding contract is incomplete."

psql_admin <<'SQL' >/dev/null
INSERT INTO governance.principal_registry (
  principal_key, display_name, identity_provider,
  external_subject, canonical_sales_rep, active
)
VALUES
  ('verify-sso-rep','Verify SSO Rep','verify_oidc','verify-sub-rep','Verify SSO Rep',true),
  ('verify-sso-admin','Verify SSO Admin','local',NULL,NULL,true);

INSERT INTO governance.role_assignment (principal_key, role_key)
VALUES
  ('verify-sso-rep','sales_rep'),
  ('verify-sso-admin','revenue_admin');

WITH p AS (
  SELECT *
  FROM governance.resolve_relative_period('this_month', now())
),
cfg AS (
  SELECT trim(both FROM currency_code::text) AS currency_code
  FROM governance.business_config
  ORDER BY updated_at DESC
  LIMIT 1
)
INSERT INTO reporting.deals (
  connector_key, source_record_id, deal_name, amount, currency_code,
  stage_name, stage_category, sales_rep, lead_source,
  created_at, expected_close_date, closed_at, source_updated_at,
  source_payload_hash, contract_version, ingested_at
)
SELECT * FROM (
  SELECT
    'rest_ingestion_api'::text, 'sso-verify-own'::text,
    'SSO Verify Own'::text, 1000::numeric, cfg.currency_code::char(3),
    'Prospecting'::text, 'open'::text, 'Verify SSO Rep'::text, 'VerifySSO'::text,
    p.start_at, p.start_at + interval '3 days', NULL::timestamptz, p.start_at,
    md5('sso-verify-own'), 1, now()
  FROM p,cfg
  UNION ALL
  SELECT
    'rest_ingestion_api', 'sso-verify-other',
    'SSO Verify Other', 9000, cfg.currency_code::char(3),
    'Prospecting', 'open', 'Different Rep', 'VerifySSO',
    p.start_at, p.start_at + interval '3 days', NULL::timestamptz, p.start_at,
    md5('sso-verify-other'), 1, now()
  FROM p,cfg
) AS fixtures(
  connector_key, source_record_id, deal_name, amount, currency_code,
  stage_name, stage_category, sales_rep, lead_source,
  created_at, expected_close_date, closed_at, source_updated_at,
  source_payload_hash, contract_version, ingested_at
)
ON CONFLICT (connector_key, source_record_id) DO UPDATE SET
  amount=EXCLUDED.amount,
  sales_rep=EXCLUDED.sales_rep,
  source_payload_hash=EXCLUDED.source_payload_hash,
  ingested_at=now();
SQL

resolver_state="$(psql_admin -c "
  SELECT mapped::int || '|' || COALESCE(principal_key,'')
  FROM governance.resolve_external_principal('verify_oidc','verify-sub-rep');
")"
[[ "$resolver_state" == "1|verify-sso-rep" ]] ||   fail "external subject did not resolve to the expected principal."

python3 - <<'PY'
import json, os, urllib.error, urllib.request

url = f"http://127.0.0.1:{os.environ.get('N8N_PORT', '5681')}/webhook/revint/v2/report-sso"
key = os.environ["SSO_INTERNAL_API_KEY"]

def post(subject, internal_key, principal="verify-sso-admin"):
    payload = {
        "principal_key": principal,
        "question": "What is our open pipeline this month?"
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "X-Revint-Sso-Internal-Key": internal_key,
            "X-Revint-Sso-Provider": "verify_oidc",
            "X-Revint-Sso-Subject": subject,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as res:
            return res.status, json.loads(res.read().decode())
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()
        try:
            body = json.loads(raw)
        except Exception:
            body = {"raw": raw}
        return exc.code, body

status, _ = post("verify-sub-rep", "wrong-internal-key")
if status != 403:
    raise SystemExit(f"FAIL: invalid internal SSO key returned {status}, expected 403")

status, body = post("verify-sub-rep", key, principal="verify-sso-admin")
value = body.get("report",{}).get("current_period",{}).get("value")
if status != 200 or body.get("status") != "success" or float(value) != 1000.0:
    raise SystemExit(
        "FAIL: SSO principal binding did not override spoofed admin principal: "
        f"{status} {body}"
    )

status, body = post("unknown-subject", key, principal="verify-sso-admin")
if status != 403 or body.get("status") != "rejected":
    raise SystemExit(f"FAIL: unmapped SSO subject was not denied: {status} {body}")

print("PASS: internal SSO credential rejects unauthorized callers.")
print("PASS: authenticated external subject overrides client-supplied principal identity.")
print("PASS: unmapped external subjects are denied by the existing authorization layer.")
PY

audit_state="$(psql_admin -c "
  SELECT count(*)
  FROM audit.agent_events
  WHERE stage='agent_core'
    AND payload->>'principal_key'='verify-sso-rep'
    AND payload->>'authentication_source'='sso';
")"
[[ "$audit_state" -ge 1 ]] ||   fail "SSO-authenticated report event was not audited with its authentication source."

[[ "$OAUTH2_PROXY_IMAGE" == *@sha256:* ]] || fail "OAuth2 Proxy image is not immutable."
resolved_sso_image="$("${compose[@]}" --profile sso config --images | grep 'oauth2-proxy' || true)"
[[ "$resolved_sso_image" == "$OAUTH2_PROXY_IMAGE" ]] ||   fail "Compose does not resolve the pinned OAuth2 Proxy image."

version_out="$(docker run --rm "$OAUTH2_PROXY_IMAGE" --version 2>&1)"
grep -q 'v7.15.4' <<<"$version_out" || fail "OAuth2 Proxy pinned image is not v7.15.4."

https_base="https://$PUBLIC_DOMAIN:$INGRESS_HTTPS_PORT"
resolve=(--resolve "$PUBLIC_DOMAIN:$INGRESS_HTTPS_PORT:127.0.0.1")

sso_status="$(curl -sS --cacert "$CERT" "${resolve[@]}" -o /dev/null -w '%{http_code}'   -H 'Content-Type: application/json' -d '{}' "$https_base/sso/report")"
[[ "$sso_status" == "404" ]] || fail "disabled SSO report ingress is not closed."

oauth_status="$(curl -sS --cacert "$CERT" "${resolve[@]}" -o /dev/null -w '%{http_code}'   "$https_base/oauth2/start")"
[[ "$oauth_status" == "404" ]] || fail "disabled OAuth2 login ingress is not closed."

if bash "$ROOT_DIR/scripts/deploy-external-sso.sh"   --confirm WRONG_TOKEN >/tmp/revint-sso-guard.out 2>&1; then
  fail "external SSO deployment accepted an invalid confirmation token."
fi
grep -q 'external SSO confirmation token is missing' /tmp/revint-sso-guard.out ||   fail "external SSO activation guard failed for an unexpected reason."
rm -f /tmp/revint-sso-guard.out

echo "PASS: external-principal resolver is executable without exposing identity tables."
echo "PASS: SSO internal credential is encrypted and both report webhooks are active."
echo "PASS: OAuth2 Proxy is pinned to the verified v7.15.4 image."
echo "PASS: external OAuth2 and SSO routes remain closed while SSO_ENABLED=false."
echo "PASS: real external SSO activation requires its explicit confirmation token."

bash "$ROOT_DIR/scripts/verify-https-ingress.sh"

echo "PASS: external SSO stage verification passed."

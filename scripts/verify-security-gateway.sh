#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  REPORTING_DB_ADMIN_USER REPORTING_DB_NAME
  REPORTING_DB_READER_USER REPORTING_DB_READER_PASSWORD
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

compose=(
  docker compose
  -p "${COMPOSE_PROJECT_NAME:-revint-agent}"
  --env-file "$ENV_FILE"
  -f "$COMPOSE_FILE"
)

TEST_DB="revint_security_verify_$$"
cleanup() {
  "${compose[@]}" exec -T reporting-db dropdb     --if-exists -U "$REPORTING_DB_ADMIN_USER" "$TEST_DB"     >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${compose[@]}" exec -T reporting-db createdb   -U "$REPORTING_DB_ADMIN_USER" "$TEST_DB"

"${compose[@]}" exec -T reporting-db pg_dump   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" --no-owner   | "${compose[@]}" exec -T reporting-db       psql -X -v ON_ERROR_STOP=1       -U "$REPORTING_DB_ADMIN_USER" -d "$TEST_DB" >/dev/null

SECURITY_GATEWAY_DB_NAME="$TEST_DB"   bash "$ROOT_DIR/scripts/init-security-gateway.sh" >/dev/null

psql_admin() {
  "${compose[@]}" exec -T reporting-db     psql -X -q -A -t -v ON_ERROR_STOP=1     -U "$REPORTING_DB_ADMIN_USER" -d "$TEST_DB" "$@"
}

state="$(psql_admin -c "
SELECT
  (SELECT count(*) FROM governance.tenant_registry WHERE active) || '|' ||
  (SELECT tenant_key FROM governance.deployment_security_config WHERE config_id=1) || '|' ||
  (SELECT principal_key FROM governance.resolve_active_service_identity('report_api')) || '|' ||
  (SELECT deployment_mode FROM governance.deployment_security_config WHERE config_id=1);
")"
[[ "$state" == "1|default|service:report-api|isolated" ]] || {
  echo "FAIL: initial isolated security state is incorrect: $state"
  exit 1
}

psql_admin <<'SQL' >/dev/null
INSERT INTO governance.tenant_registry(tenant_key,display_name,active)
VALUES ('other-tenant','Other tenant',true);

INSERT INTO governance.principal_registry(
  principal_key,display_name,identity_provider,external_subject,
  canonical_sales_rep,active,tenant_key
)
VALUES
  ('verify-sec-default','Default principal','verify_oidc','same-sub',NULL,true,'default'),
  ('verify-sec-other','Other principal','verify_oidc','same-sub',NULL,true,'other-tenant');
SQL

resolved="$(psql_admin -c "
SELECT mapped::int || '|' || COALESCE(principal_key,'')
FROM governance.resolve_external_principal('verify_oidc','same-sub');
")"
[[ "$resolved" == "1|verify-sec-default" ]] || {
  echo "FAIL: SSO resolver crossed tenant boundary: $resolved"
  exit 1
}
psql_admin -c "
UPDATE governance.deployment_security_config
SET tenant_key='other-tenant',updated_at=now()
WHERE config_id=1;
" >/dev/null

resolved_other="$(psql_admin -c "
SELECT mapped::int || '|' || COALESCE(principal_key,'')
FROM governance.resolve_external_principal('verify_oidc','same-sub');
")"
[[ "$resolved_other" == "1|verify-sec-other" ]] || {
  echo "FAIL: deployment tenant switch did not bind SSO correctly."
  exit 1
}

service_other="$(psql_admin -c "
SELECT mapped::int || '|' || COALESCE(principal_key,'')
FROM governance.resolve_active_service_identity('report_api');
")"
[[ "$service_other" == "0|" ]] || {
  echo "FAIL: report service leaked across tenant boundary: $service_other"
  exit 1
}

psql_admin -c "
UPDATE governance.deployment_security_config
SET tenant_key='default',updated_at=now()
WHERE config_id=1;
" >/dev/null
duplicate_ok=0
if psql_admin <<'SQL' >/dev/null 2>&1
INSERT INTO governance.principal_registry(
  principal_key,display_name,identity_provider,active,tenant_key
)
VALUES ('verify-sec-service','Verify Service','service',true,'default');

INSERT INTO governance.service_identity_registry(
  service_key,tenant_key,principal_key,display_name,
  allowed_routes,active
)
VALUES (
  'verify-second-report','default','verify-sec-service','Duplicate route',
  ARRAY['report_api']::text[],true
);
SQL
then
  duplicate_ok=1
fi

[[ "$duplicate_ok" == "0" ]] || {
  echo "FAIL: duplicate active report route was accepted."
  exit 1
}

privs="$(psql_admin -c "
SELECT
  has_function_privilege(
    '$REPORTING_DB_READER_USER',
    'governance.resolve_active_service_identity(text)','EXECUTE'
  )::int || '|' ||
  has_table_privilege(
    '$REPORTING_DB_READER_USER',
    'governance.service_identity_registry','SELECT'
  )::int;
")"
[[ "$privs" == "1|0" ]] || {
  echo "FAIL: service identity privilege boundary is incorrect: $privs"
  exit 1
}

SECURITY_GATEWAY_DB_NAME="$TEST_DB"   bash "$ROOT_DIR/scripts/configure-security-tenant.sh"     --tenant-key verify-client     --display-name "Verify Client" >/dev/null

tenant_handover="$(psql_admin -c "
SELECT
  (SELECT tenant_key FROM governance.deployment_security_config WHERE config_id=1)
  || '|' ||
  (SELECT tenant_key FROM governance.service_identity_registry WHERE service_key='report_api')
  || '|' ||
  (SELECT principal_key FROM governance.resolve_active_service_identity('report_api'));
")"
[[ "$tenant_handover" == "verify-client|verify-client|service:report-api" ]] || {
  echo "FAIL: client tenant handover did not preserve service binding: $tenant_handover"
  exit 1
}

grep -q 'limit_req zone=revint_report'   "$ROOT_DIR/deploy/nginx/revint.conf.template"
grep -q 'client_max_body_size ${REPORT_MAX_BODY_SIZE}'   "$ROOT_DIR/deploy/nginx/revint.conf.template"
grep -q 'proxy_set_header X-Revint-Sso-Subject "";'   "$ROOT_DIR/deploy/nginx/revint.conf.template"

python3 - <<'PY'
import json
from pathlib import Path
p=Path('workflows/runtime-templates/REVINT-V2-AGENT-01.json')
d=json.loads(p.read_text())
w=d[0] if isinstance(d,list) else d
names={n['name'] for n in w['nodes']}
required={'DB | Resolve Report Service','CTX | Bind Report Service'}
assert required <= names, names
edge=w['connections']['INT | Authenticated Report Request']['main'][0][0]['node']
assert edge=='DB | Resolve Report Service', edge
bind=next(n for n in w['nodes'] if n['name']=='CTX | Bind Report Service')
code=bind['parameters']['jsCode']
assert "principal_key: principal || '__service_unmapped__'" in code
assert "REQUEST_BODY_TOO_LARGE" in code
print('PASS: workflow binds machine callers to the configured service principal.')
PY
echo "PASS: SSO identities are scoped to the active deployment tenant."
echo "PASS: machine report route resolves one fixed service principal."
echo "PASS: duplicate active service-route bindings fail closed."
echo "PASS: reporting reader can resolve service identity without reading its registry."
echo "PASS: ingress has report/SSO/ingest resource controls and spoofable-header stripping."
echo "PASS: reusable Agent V2 security gateway verification passed."

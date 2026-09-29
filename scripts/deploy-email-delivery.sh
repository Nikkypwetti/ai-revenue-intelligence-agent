#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-EMAIL-01.json"
CONFIRM=""
fail(){ echo "FAIL: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do case "$1" in --confirm) CONFIRM="${2:-}"; shift 2;; *) fail "unknown argument: $1";; esac; done
[[ "$CONFIRM" == "REVINT_EMAIL_DELIVERY" ]] || fail "email delivery confirmation token is missing or incorrect."
set -a; source "$ENV_FILE"; set +a
[[ "${EMAIL_REPORT_ENABLED:-false}" == "true" ]] || fail "EMAIL_REPORT_ENABLED must be true."
: "${EMAIL_REPORT_RECIPIENT:?Missing EMAIL_REPORT_RECIPIENT}"
: "${EMAIL_REPORT_RECIPIENT_NAME:?Missing EMAIL_REPORT_RECIPIENT_NAME}"
[[ "$EMAIL_REPORT_RECIPIENT" != CHANGE_ME* && "$EMAIL_REPORT_RECIPIENT_NAME" != CHANGE_ME* ]] || fail "email recipient fields still use placeholders."
[[ "$EMAIL_REPORT_RECIPIENT" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail "EMAIL_REPORT_RECIPIENT is invalid."
subject_max="${EMAIL_REPORT_MAX_SUBJECT_CHARS:-180}"; body_max="${EMAIL_REPORT_MAX_BODY_CHARS:-20000}"
[[ "$subject_max" =~ ^[0-9]+$ && "$subject_max" -ge 40 && "$subject_max" -le 300 ]] || fail "EMAIL_REPORT_MAX_SUBJECT_CHARS invalid."
[[ "$body_max" =~ ^[0-9]+$ && "$body_max" -ge 1000 && "$body_max" -le 50000 ]] || fail "EMAIL_REPORT_MAX_BODY_CHARS invalid."

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
bash "$ROOT_DIR/scripts/init-email-delivery.sh"
credential_row="$("${compose[@]}" exec -T n8n-db psql -X -q -A -t -F '|' -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
SELECT id, count(*) OVER (), (data NOT LIKE '{%')::int
FROM credentials_entity
WHERE name='REVINT | Gmail Reports' AND type='gmailOAuth2';
")"
[[ -n "$credential_row" ]] || fail "dedicated Gmail credential named REVINT | Gmail Reports is missing."
IFS='|' read -r gmail_credential_id gmail_credential_count gmail_encrypted <<< "$credential_row"
[[ "$gmail_credential_count" == "1" && "$gmail_encrypted" == "1" ]] || fail "Gmail credential must exist exactly once and be stored encrypted."

tmp_workflow="$(mktemp)"
trap 'rm -f "$tmp_workflow"; "${compose[@]}" up -d n8n >/dev/null 2>&1 || true' EXIT
python3 - "$WORKFLOW" "$tmp_workflow" "$gmail_credential_id" <<'PY'
import json,sys
src,dst,credential_id=sys.argv[1:4]
doc=json.load(open(src))
found=False
for workflow in doc:
    for node in workflow.get("nodes",[]):
        if node.get("name")=="DEL | Send Gmail Report":
            node["credentials"]["gmailOAuth2"]["id"]=credential_id
            node["credentials"]["gmailOAuth2"]["name"]="REVINT | Gmail Reports"
            found=True
if not found:
    raise SystemExit("FAIL: Gmail delivery node not found.")
json.dump(doc,open(dst,"w"),indent=2)
PY

"${compose[@]}" stop n8n >/dev/null
cat "$tmp_workflow" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2EMAIL01 >/dev/null
"${compose[@]}" up -d n8n >/dev/null
for i in $(seq 1 40); do if curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1; then break; fi; [[ "$i" -lt 40 ]] || fail "Agent V2 did not recover."; sleep 2; done

safe_email="$(printf %s "$EMAIL_REPORT_RECIPIENT" | sed "s/'/''/g")"
safe_name="$(printf %s "$EMAIL_REPORT_RECIPIENT_NAME" | sed "s/'/''/g")"
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1 -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
UPDATE governance.email_delivery_config SET email_report_enabled=true,max_subject_chars=$subject_max,max_body_chars=$body_max,updated_at=now() WHERE config_id=1;
INSERT INTO governance.email_destination_registry(destination_key,tenant_key,purpose_key,recipient_email,display_name,active)
SELECT 'manager_email',tenant_key,'manager_report','$safe_email','$safe_name',true FROM governance.deployment_security_config WHERE config_id=1
ON CONFLICT(destination_key) DO UPDATE SET recipient_email=EXCLUDED.recipient_email,display_name=EXCLUDED.display_name,active=true,updated_at=now();" >/dev/null
trap - EXIT
echo "PASS: governed Gmail report delivery adapter deployed and enabled."
echo "NOTE: Agent Core invocation is a separate integration step after local Agent Core changes are reconciled."

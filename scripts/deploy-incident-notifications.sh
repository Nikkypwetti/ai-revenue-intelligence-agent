#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-INCIDENT-01.json"
SYS_WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SYS-01.json"
CONFIRM=""

fail(){ echo "FAIL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ "$CONFIRM" == "REVINT_INCIDENT_NOTIFICATIONS" ]] || fail "incident notification confirmation token is missing or incorrect."

set -a
source "$ENV_FILE"
set +a

[[ "${INCIDENT_SLACK_ENABLED:-false}" == "true" ]] || fail "INCIDENT_SLACK_ENABLED must be true for activation."
: "${INCIDENT_SLACK_CHANNEL_ID:?Missing INCIDENT_SLACK_CHANNEL_ID}"
: "${INCIDENT_SLACK_CHANNEL_NAME:?Missing INCIDENT_SLACK_CHANNEL_NAME}"
[[ "$INCIDENT_SLACK_CHANNEL_ID" != CHANGE_ME* ]] || fail "incident channel ID is still a placeholder."
[[ "$INCIDENT_SLACK_CHANNEL_NAME" != CHANGE_ME* ]] || fail "incident channel name is still a placeholder."

severity="${INCIDENT_MIN_SEVERITY:-warning}"
cooldown="${INCIDENT_COOLDOWN_SECONDS:-3600}"
[[ "$severity" == "warning" || "$severity" == "critical" ]] || fail "INCIDENT_MIN_SEVERITY must be warning or critical."
[[ "$cooldown" =~ ^[0-9]+$ && "$cooldown" -ge 300 && "$cooldown" -le 86400 ]] || fail "INCIDENT_COOLDOWN_SECONDS must be between 300 and 86400."

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

bash "$ROOT_DIR/scripts/init-incident-notifications.sh"
bash "$ROOT_DIR/scripts/import-incident-slack-credential.sh"

# Keep governance disabled while runtime workflow assets are changed.
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
  UPDATE governance.incident_notification_config SET enabled=false, updated_at=now() WHERE config_id=1;
  UPDATE governance.reliability_policy SET active=false, updated_at=now() WHERE component_key='incident_notifications';
" >/dev/null

restore_n8n(){ "${compose[@]}" up -d n8n >/dev/null 2>&1 || true; }
trap restore_n8n EXIT
"${compose[@]}" stop n8n >/dev/null

cat "$SYS_WORKFLOW" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2SYSERROR01 >/dev/null
cat "$WORKFLOW" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2INCIDENT01 >/dev/null

"${compose[@]}" up -d n8n >/dev/null
for i in $(seq 1 40); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1; then break; fi
  [[ "$i" -lt 40 ]] || fail "Agent V2 n8n did not recover."
  sleep 2
done

safe_channel="$(printf %s "$INCIDENT_SLACK_CHANNEL_ID" | sed "s/'/''/g")"
safe_name="$(printf %s "$INCIDENT_SLACK_CHANNEL_NAME" | sed "s/'/''/g")"
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
  UPDATE governance.incident_notification_config
  SET enabled=true,
      provider='slack',
      destination_id='$safe_channel',
      destination_name='$safe_name',
      min_severity='$severity',
      cooldown_seconds=$cooldown,
      updated_at=now()
  WHERE config_id=1;
  UPDATE governance.reliability_policy SET active=true, updated_at=now()
  WHERE component_key='incident_notifications';
  INSERT INTO governance.circuit_state(component_key)
  VALUES ('incident_notifications') ON CONFLICT (component_key) DO NOTHING;
" >/dev/null

trap - EXIT
echo "PASS: governed incident notifications activated."

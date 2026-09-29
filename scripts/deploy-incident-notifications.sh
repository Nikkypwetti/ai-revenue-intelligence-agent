#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
INCIDENT_WF="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-INCIDENT-01.json"
SYS_WF="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SYS-01.json"
CONFIRM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    *) echo "FAIL: unknown argument $1"; exit 1 ;;
  esac
done

[[ "$CONFIRM" == "REVINT_INCIDENT_SLACK" ]] || { echo "FAIL: explicit incident activation confirmation required."; exit 1; }

set -a
source "$ENV_FILE"
set +a

[[ "${INCIDENT_SLACK_ENABLED:-false}" == "true" ]] || { echo "FAIL: INCIDENT_SLACK_ENABLED must be true."; exit 1; }
for name in INCIDENT_SLACK_ACCESS_TOKEN INCIDENT_SLACK_CHANNEL_ID REPORTING_DB_ADMIN_USER REPORTING_DB_NAME; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || { echo "FAIL: $name missing or placeholder."; exit 1; }
done

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

bash "$ROOT_DIR/scripts/init-incident-notifications.sh"
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1 \
  -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
  UPDATE governance.reliability_policy SET active=false,updated_at=now()
  WHERE component_key='incident_notification';
" >/dev/null

"${compose[@]}" stop n8n >/dev/null
restore(){ "${compose[@]}" up -d n8n >/dev/null 2>&1 || true; }
trap restore EXIT

bash "$ROOT_DIR/scripts/import-slack-incident-credential.sh"
for pair in "$SYS_WF:REVINTV2SYSERROR01" "$INCIDENT_WF:REVINTV2INCIDENT01"; do
  file="${pair%%:*}"; id="${pair##*:}"
  cat "$file" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
  "${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id="$id" >/dev/null
done

"${compose[@]}" up -d n8n >/dev/null
for i in $(seq 1 40); do
  curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1 && break
  [[ "$i" -lt 40 ]] || { echo "FAIL: Agent V2 n8n did not recover."; exit 1; }
  sleep 2
done

"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1 \
  -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
  UPDATE governance.reliability_policy SET active=true,updated_at=now()
  WHERE component_key='incident_notification';
  INSERT INTO governance.circuit_state(component_key)
  VALUES ('incident_notification')
  ON CONFLICT (component_key) DO NOTHING;
" >/dev/null

trap - EXIT
echo "PASS: external Slack incident notification adapter activated."

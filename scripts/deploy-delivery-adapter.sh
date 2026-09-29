#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
CONFIRM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    *) echo "FAIL: unknown argument $1"; exit 1 ;;
  esac
done

[[ "$CONFIRM" == "REVINT_DELIVERY_ADAPTER" ]] || {
  echo "FAIL: explicit confirmation required: --confirm REVINT_DELIVERY_ADAPTER"; exit 1;
}

set -a
source "$ENV_FILE"
set +a

enabled="${SLACK_REPORT_ENABLED:-false}"
[[ "$enabled" == "true" || "$enabled" == "false" ]] || {
  echo "FAIL: SLACK_REPORT_ENABLED must be true or false."; exit 1;
}

bash "$ROOT_DIR/scripts/init-delivery-adapter.sh"
compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME"   -c "UPDATE governance.delivery_adapter_config
      SET slack_report_enabled=false,updated_at=now()
      WHERE config_id=1;" >/dev/null

if [[ "$enabled" == "true" ]]; then
  bash "$ROOT_DIR/scripts/import-slack-report-credential.sh"
fi

cleanup() {
  "${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2DELIVERY01 >/dev/null 2>&1 || true
  "${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2AGENTCORE01 >/dev/null 2>&1 || true
  "${compose[@]}" up -d n8n >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${compose[@]}" stop n8n >/dev/null

cat "$ROOT_DIR/workflows/runtime-templates/REVINT-V2-DELIVERY-01.json" |   "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2DELIVERY01 >/dev/null

cat "$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AGENT-01.json" |   "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2AGENTCORE01 >/dev/null

"${compose[@]}" up -d n8n >/dev/null
for i in $(seq 1 40); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1; then break; fi
  [[ "$i" -lt 40 ]] || { echo "FAIL: Agent V2 health did not recover."; exit 1; }
  sleep 2
done

"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME"   -c "UPDATE governance.delivery_adapter_config
      SET slack_report_enabled=$enabled,updated_at=now()
      WHERE config_id=1;" >/dev/null

trap - EXIT
echo "PASS: Agent V2 delivery adapter deployed."
echo "Slack report enabled: $enabled"

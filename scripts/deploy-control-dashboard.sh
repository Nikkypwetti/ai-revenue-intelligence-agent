#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-CONTROL-01.json"
CONFIRMATION=""

fail(){ echo "FAIL: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRMATION="${2:-}"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$CONFIRMATION" == "REVINT_CONTROL_DASHBOARD" ]] || fail "control dashboard confirmation token is missing or incorrect."
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ -f "$WORKFLOW" ]] || fail "control dashboard workflow template is missing."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(N8N_DB_USER N8N_DB_NAME)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || fail "$name is missing or uses a placeholder."
done

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
n8n_stopped=false

cleanup(){
  if [[ "$n8n_stopped" == "true" ]]; then
    "${compose[@]}" up -d n8n >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

credential_state="$("${compose[@]}" exec -T n8n-db psql -X -q -A -t \
  -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
    SELECT count(*) || '|' || count(*) FILTER (WHERE data NOT LIKE '{%')
    FROM credentials_entity
    WHERE id='REVINTPGREPORTRO001'
      AND type='postgres';
  ")"
[[ "$credential_state" == "1|1" ]] || fail "encrypted Reporting RO credential REVINTPGREPORTRO001 is missing."

"${compose[@]}" stop n8n >/dev/null
n8n_stopped=true

cat "$WORKFLOW" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2CONTROL01 >/dev/null

"${compose[@]}" up -d n8n >/dev/null
n8n_stopped=false

port="${N8N_PORT:-5681}"
for attempt in $(seq 1 40); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
    break
  fi
  [[ "$attempt" -lt 40 ]] || fail "Agent V2 n8n did not recover after control dashboard deployment."
  sleep 2
done

workflow_state="$("${compose[@]}" exec -T n8n-db psql -X -q -A -t -F '|' \
  -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
    SELECT active::int, (\"versionId\" = \"activeVersionId\")::int
    FROM workflow_entity
    WHERE id='REVINTV2CONTROL01';
  ")"
[[ "$workflow_state" == "1|1" ]] || fail "control dashboard workflow is not active and published."

trap - EXIT

echo "PASS: Agent V2 local read-only control dashboard deployed."
echo "OPEN: http://localhost:$port/webhook/revint/v2/control"
echo "NOTE: this path is local-only and is not routed by the public ingress."

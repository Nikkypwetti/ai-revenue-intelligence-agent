#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

ERROR_WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SYS-01.json"
RUNTIME_WORKFLOWS=(
  "$ROOT_DIR/workflows/runtime-templates/REVINT-V2-REST-01.json"
  "$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AGENT-01.json"
  "$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SCHEDULED-01.json"
)

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
[[ -f "$ERROR_WORKFLOW" ]] || { echo "FAIL: reliability error workflow is missing."; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

bash "$ROOT_DIR/scripts/init-reliability-core.sh"

cat "$ERROR_WORKFLOW" | docker compose   --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n import:workflow --input=/dev/stdin

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n publish:workflow --id=REVINTV2SYSERROR01

for workflow in "${RUNTIME_WORKFLOWS[@]}"; do
  cat "$workflow" | docker compose     --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n     n8n import:workflow --input=/dev/stdin
done

for workflow_id in   REVINTV2RESTINGEST01   REVINTV2AGENTCORE01   REVINTV2SCHEDULED01; do
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n     n8n publish:workflow --id="$workflow_id"
done

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE"   up -d --force-recreate n8n

port="${N8N_PORT:-5681}"
for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
    break
  fi
  [[ "$attempt" -ne 30 ]] || {
    echo "FAIL: Agent v2 n8n did not become healthy."
    exit 1
  }
  sleep 2
done

echo "PASS: reliability error workflow and protected Agent v2 workflows deployed."

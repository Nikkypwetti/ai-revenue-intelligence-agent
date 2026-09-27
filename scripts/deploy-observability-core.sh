#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
SYS_WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SYS-01.json"
OBS_WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-OBS-01.json"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
[[ -f "$SYS_WORKFLOW" ]] || { echo "FAIL: reliability workflow is missing."; exit 1; }
[[ -f "$OBS_WORKFLOW" ]] || { echo "FAIL: observability workflow is missing."; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

bash "$ROOT_DIR/scripts/init-observability-core.sh"

import_publish() {
  local file="$1"
  local workflow_id="$2"
  cat "$file" | docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n \
    n8n import:workflow --input=/dev/stdin
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n \
    n8n publish:workflow --id="$workflow_id"
}

import_publish "$SYS_WORKFLOW" "REVINTV2SYSERROR01"
import_publish "$OBS_WORKFLOW" "REVINTV2OBS01"

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --force-recreate n8n

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

echo "PASS: Agent v2 observability workflow deployed and healthy."

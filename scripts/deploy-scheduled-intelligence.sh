#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-SCHEDULED-01.json"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
[[ -f "$WORKFLOW" ]] || { echo "FAIL: scheduled-intelligence workflow is missing."; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

bash "$ROOT_DIR/scripts/init-scheduled-intelligence.sh"

cat "$WORKFLOW" | docker compose \
  --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n \
  n8n import:workflow --input=/dev/stdin

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n \
  n8n publish:workflow --id=REVINTV2SCHEDULED01

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" \
  up -d --force-recreate n8n

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

workflow_state="$(docker compose \
  --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n-db \
  psql -X -q -A -t -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
    SELECT active::int || '|' ||
           (\"versionId\" = \"activeVersionId\")::int || '|' ||
           (
             SELECT count(*)
             FROM json_array_elements(nodes) n
             WHERE n->>'type'='n8n-nodes-base.scheduleTrigger'
           )
    FROM workflow_entity
    WHERE id='REVINTV2SCHEDULED01';
  ")"

[[ "$workflow_state" == "1|1|2" ]] || {
  echo "FAIL: scheduled-intelligence workflow is not active with two schedule triggers."
  exit 1
}

echo "PASS: scheduled-intelligence workflow deployed."
echo "PASS: daily and weekly Schedule Trigger nodes are active."

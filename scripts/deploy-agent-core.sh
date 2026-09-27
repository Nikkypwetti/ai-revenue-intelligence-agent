#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AGENT-01.json"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
[[ -f "$WORKFLOW" ]] || { echo "FAIL: Agent core workflow template is missing."; exit 1; }

set -a
source "$ENV_FILE"
set +a

bash "$ROOT_DIR/scripts/init-agent-execution-core.sh"
bash "$ROOT_DIR/scripts/import-agent-runtime-credential.sh"

cat "$WORKFLOW" | docker compose   --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n import:workflow --input=/dev/stdin

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n publish:workflow --id=REVINTV2AGENTCORE01

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE"   up -d --force-recreate n8n

port="${N8N_PORT:-5681}"
for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then break; fi
  [[ "$attempt" -ne 30 ]] || { echo "FAIL: Agent v2 n8n did not become healthy."; exit 1; }
  sleep 2
done

registered=0
for attempt in $(seq 1 30); do
  registered="$(docker compose     --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n-db     psql -X -q -A -t -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
      SELECT count(*)
      FROM webhook_entity
      WHERE \"workflowId\"='REVINTV2AGENTCORE01'
        AND \"webhookPath\"='revint/v2/report'
        AND method='POST';
    ")"
  [[ "$registered" == "1" ]] && break
  sleep 2
done

[[ "$registered" == "1" ]] || { echo "FAIL: Agent report webhook did not register."; exit 1; }
echo "PASS: Agent execution core deployed on Agent v2 port $port."
echo "PASS: POST /webhook/revint/v2/report is registered."

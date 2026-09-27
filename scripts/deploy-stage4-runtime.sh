#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
CONNECTOR_CONFIG_FILE="${CONNECTOR_CONFIG_FILE:-$ROOT_DIR/config/connectors.local.json}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-REST-01.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL: $ENV_FILE does not exist."
  exit 1
fi

if [[ ! -f "$CONNECTOR_CONFIG_FILE" ]]; then
  echo "FAIL: create $CONNECTOR_CONFIG_FILE from config/rest-ingestion.example.json."
  exit 1
fi

if [[ ! -f "$WORKFLOW" ]]; then
  echo "FAIL: Stage 4 workflow template is missing."
  exit 1
fi

set -a
source "$ENV_FILE"
set +a
bash "$ROOT_DIR/scripts/import-runtime-credentials.sh"

CONNECTOR_CONFIG_FILE="$CONNECTOR_CONFIG_FILE"   bash "$ROOT_DIR/scripts/apply-connector-config.sh"

cat "$WORKFLOW" | docker compose   --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n import:workflow --input=/dev/stdin

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n publish:workflow --id=REVINTV2RESTINGEST01

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE"   up -d --force-recreate n8n

port="${N8N_PORT:-5681}"
for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    echo "FAIL: Agent v2 n8n did not become healthy."
    exit 1
  fi
  sleep 2
done
registered=0
for attempt in $(seq 1 30); do
  registered="$(docker compose     --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n-db     psql -X -q -A -t -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
      SELECT count(*)
      FROM webhook_entity
      WHERE \"workflowId\"='REVINTV2RESTINGEST01'
        AND \"webhookPath\"='revint/v2/deals'
        AND method='POST';
    ")"
  [[ "$registered" == "1" ]] && break
  sleep 2
done

[[ "$registered" == "1" ]] || {
  echo "FAIL: Stage 4 production webhook did not register."
  exit 1
}

echo "PASS: Stage 4 runtime deployed on Agent v2 port $port."
echo "PASS: POST /webhook/revint/v2/deals is registered."

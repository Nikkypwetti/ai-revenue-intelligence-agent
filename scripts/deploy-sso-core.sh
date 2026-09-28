#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AGENT-01.json"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
[[ -f "$WORKFLOW" ]] || { echo "FAIL: Agent workflow template is missing."; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

bash "$ROOT_DIR/scripts/init-external-sso.sh"
bash "$ROOT_DIR/scripts/import-sso-runtime-credential.sh"

cat "$WORKFLOW" | docker compose   --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n import:workflow --input=/dev/stdin

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n publish:workflow --id=REVINTV2AGENTCORE01

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE"   up -d --force-recreate n8n

port="${N8N_PORT:-5681}"
for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then break; fi
  [[ "$attempt" -ne 30 ]] || { echo "FAIL: Agent v2 n8n did not become healthy."; exit 1; }
  sleep 2
done

report_status=""
sso_status=""
for attempt in $(seq 1 30); do
  report_status="$(curl -sS -o /dev/null -w '%{http_code}'     -H 'Content-Type: application/json'     -d '{}' "http://127.0.0.1:$port/webhook/revint/v2/report" 2>/dev/null || true)"
  sso_status="$(curl -sS -o /dev/null -w '%{http_code}'     -H 'Content-Type: application/json'     -H 'X-Revint-Sso-Internal-Key: invalid-verification-key'     -d '{}' "http://127.0.0.1:$port/webhook/revint/v2/report-sso" 2>/dev/null || true)"
  if [[ "$report_status" == "403" && "$sso_status" == "403" ]]; then
    break
  fi
  [[ "$attempt" -ne 30 ]] || {
    echo "FAIL: report API and SSO report webhooks did not become active behind header authentication."
    exit 1
  }
  sleep 2
done

echo "PASS: external SSO principal resolver and internal SSO report route deployed."
echo "PASS: report API and SSO report webhooks are active behind their header-auth boundaries."

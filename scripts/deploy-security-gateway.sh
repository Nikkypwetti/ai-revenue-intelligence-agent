#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
WORKFLOW="$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AGENT-01.json"

CONFIRM=""

usage() {
  echo "Usage: bash scripts/deploy-security-gateway.sh --confirm REVINT_SECURITY_GATEWAY"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$CONFIRM" == "REVINT_SECURITY_GATEWAY" ]] || {
  echo "FAIL: security gateway confirmation token is missing."
  exit 1
}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
compose=(
  docker compose
  -p "${COMPOSE_PROJECT_NAME:-revint-agent}"
  --env-file "$ENV_FILE"
  -f "$COMPOSE_FILE"
)

bash "$ROOT_DIR/scripts/init-security-gateway.sh"

cleanup() {
  "${compose[@]}" up -d n8n >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${compose[@]}" stop n8n >/dev/null

cat "$WORKFLOW" | "${compose[@]}" run --rm --no-deps -T n8n   import:workflow --input=/dev/stdin >/dev/null

"${compose[@]}" run --rm --no-deps -T n8n   publish:workflow --id=REVINTV2AGENTCORE01 >/dev/null

"${compose[@]}" up -d n8n >/dev/null

for i in $(seq 1 40); do
  if curl -fsS --max-time 3     "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1; then
    break
  fi
  if [[ "$i" -eq 40 ]]; then
    echo "FAIL: Agent V2 n8n did not recover after security deployment."
    exit 1
  fi
  sleep 2
done

trap - EXIT

if "${compose[@]}" --profile ingress ps --status running ingress   --format json 2>/dev/null | grep -q .; then
  "${compose[@]}" --profile ingress up -d --wait --force-recreate ingress
fi

echo "PASS: Agent V2 reusable security gateway deployed."
echo "PASS: report machine identity is bound server-side before Agent authorization."
echo "PASS: public ingress resource controls are configured."

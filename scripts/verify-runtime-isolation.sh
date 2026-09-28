#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

fail() {
  echo "FAIL: $1"
  exit 1
}

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

agent_port="${N8N_PORT:-5681}"
legacy_port="${PROTECTED_LEGACY_N8N_PORT:-5678}"
legacy_required="${VERIFY_LEGACY_N8N_REQUIRED:-false}"

[[ "$agent_port" =~ ^[0-9]+$ ]] || fail "N8N_PORT must be numeric."
[[ "$legacy_port" =~ ^[0-9]+$ ]] || fail "PROTECTED_LEGACY_N8N_PORT must be numeric."
[[ "$legacy_required" == "true" || "$legacy_required" == "false" ]] || \
  fail "VERIFY_LEGACY_N8N_REQUIRED must be true or false."

[[ "$agent_port" != "$legacy_port" ]] || \
  fail "Agent v2 cannot bind protected legacy n8n port $legacy_port."

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
binding="$("${compose[@]}" port n8n 5678 2>/dev/null | tail -1)"
[[ -n "$binding" ]] || fail "Agent v2 n8n has no published host-port binding."
[[ "$binding" == *":$agent_port" ]] || \
  fail "Agent v2 n8n binding $binding does not match configured port $agent_port."

curl -fsS --max-time 10 "http://127.0.0.1:$agent_port/healthz" | \
  grep -q '"status":"ok"' || fail "Agent v2 health endpoint is not healthy on port $agent_port."

if [[ "$legacy_required" == "true" ]]; then
  ss -ltn | grep -qE ":$legacy_port[[:space:]]" || \
    fail "protected legacy n8n listener on port $legacy_port is required but missing."
fi

echo "PASS: Agent v2 binds $agent_port, not protected legacy port $legacy_port."
if [[ "$legacy_required" == "true" ]]; then
  echo "PASS: protected legacy n8n listener on port $legacy_port is available."
else
  echo "PASS: legacy n8n availability is optional for this deployment."
fi

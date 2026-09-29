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
[[ "$CONFIRM" == "REVINT_MANAGER_FORM" ]] || { echo "FAIL: use --confirm REVINT_MANAGER_FORM"; exit 1; }
set -a; source "$ENV_FILE"; set +a
compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
cleanup(){ "${compose[@]}" up -d n8n >/dev/null 2>&1 || true; }
trap cleanup EXIT
"${compose[@]}" stop n8n >/dev/null
cat "$ROOT_DIR/workflows/runtime-templates/REVINT-V2-FORM-01.json" | "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2FORM01 >/dev/null
"${compose[@]}" up -d n8n >/dev/null
for i in $(seq 1 40); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1; then break; fi
  [[ "$i" -lt 40 ]] || { echo "FAIL: Agent V2 health did not recover."; exit 1; }
  sleep 2
done
trap - EXIT
echo "PASS: Agent V2 SSO manager form deployed. /sso/form stays unavailable while SSO_ENABLED is false."

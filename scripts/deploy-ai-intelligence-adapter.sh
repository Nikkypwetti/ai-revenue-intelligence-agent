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

[[ "$CONFIRM" == "REVINT_AI_INTELLIGENCE" ]] || {
  echo "FAIL: explicit confirmation required: --confirm REVINT_AI_INTELLIGENCE"
  exit 1
}

set -a
source "$ENV_FILE"
set +a

intent_enabled="${GROQ_INTENT_ENABLED:-false}"
summary_enabled="${GROQ_SUMMARY_ENABLED:-false}"
intent_model="${GROQ_INTENT_MODEL:-openai/gpt-oss-20b}"
summary_model="${GROQ_SUMMARY_MODEL:-openai/gpt-oss-20b}"

for flag in "$intent_enabled" "$summary_enabled"; do
  [[ "$flag" == "true" || "$flag" == "false" ]] || {
    echo "FAIL: GROQ enable flags must be true or false."; exit 1;
  }
done

if [[ "$intent_enabled" == "true" || "$summary_enabled" == "true" ]]; then
  if [[ -z "${GROQ_API_KEY:-}" || "${GROQ_API_KEY}" == CHANGE_ME* ]]; then
    echo "FAIL: GROQ_API_KEY must be configured before enabling the AI adapter."
    exit 1
  fi
fi

bash "$ROOT_DIR/scripts/init-ai-intelligence-adapter.sh"

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

# Keep policy disabled while workflows/credentials are installed.
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
    UPDATE governance.ai_adapter_config
    SET intent_enabled=false, summary_enabled=false,
        intent_model='$(printf %s "$intent_model" | sed "s/'/''/g")',
        summary_model='$(printf %s "$summary_model" | sed "s/'/''/g")',
        updated_at=now()
    WHERE config_id=1;
  " >/dev/null

if [[ "$intent_enabled" == "true" || "$summary_enabled" == "true" ]]; then
  bash "$ROOT_DIR/scripts/import-groq-runtime-credential.sh"
fi

cleanup() {
  # If a CLI import is interrupted after deactivation, republish any existing current versions.
  "${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2AGENTCORE01 >/dev/null 2>&1 || true
  "${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2AIADAPTER01 >/dev/null 2>&1 || true
  "${compose[@]}" up -d n8n >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${compose[@]}" stop n8n >/dev/null

echo "IMPORT REVINT-V2-AI-01.json"
cat "$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AI-01.json" |   "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
echo "PUBLISH REVINTV2AIADAPTER01"
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2AIADAPTER01 >/dev/null

echo "IMPORT REVINT-V2-AGENT-01.json"
cat "$ROOT_DIR/workflows/runtime-templates/REVINT-V2-AGENT-01.json" |   "${compose[@]}" run --rm --no-deps -T n8n import:workflow --input=/dev/stdin >/dev/null
echo "PUBLISH REVINTV2AGENTCORE01"
"${compose[@]}" run --rm --no-deps -T n8n publish:workflow --id=REVINTV2AGENTCORE01 >/dev/null

"${compose[@]}" up -d n8n >/dev/null
for i in $(seq 1 40); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT:-5681}/healthz" >/dev/null 2>&1; then
    break
  fi
  [[ "$i" -lt 40 ]] || { echo "FAIL: Agent V2 health did not recover."; exit 1; }
  sleep 2
done

# Activate only after runtime health is confirmed.
"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
    UPDATE governance.ai_adapter_config
    SET intent_enabled=$intent_enabled,
        summary_enabled=$summary_enabled,
        updated_at=now()
    WHERE config_id=1;
  " >/dev/null

trap - EXIT

echo "PASS: Agent V2 intelligence adapter deployed."
echo "Intent AI enabled: $intent_enabled"
echo "Summary AI enabled: $summary_enabled"

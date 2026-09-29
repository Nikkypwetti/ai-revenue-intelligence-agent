#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ "${REVINT_LLM_ENABLED:-false}" != "true" ]]; then
  echo "PASS: Groq intelligence adapter is disabled; no runtime AI credential imported."
  exit 0
fi

required=(GROQ_API_KEY N8N_DB_USER N8N_DB_NAME)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

python3 - <<'PY' | "${compose[@]}" run --rm --no-deps -T n8n import:credentials --input=/dev/stdin
import json, os
print(json.dumps([{
  "id": "REVINTGROQAI001",
  "name": "REVINT | Groq AI",
  "type": "httpHeaderAuth",
  "data": {"name": "Authorization", "value": "Bearer " + os.environ["GROQ_API_KEY"]},
}], separators=(",", ":")))
PY

credential_state="$("${compose[@]}" exec -T n8n-db psql -X -q -A -t -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
  SELECT count(*) || '|' || count(*) FILTER (WHERE data NOT LIKE '{%')
  FROM credentials_entity
  WHERE id='REVINTGROQAI001' AND type='httpHeaderAuth';
")"

[[ "$credential_state" == "1|1" ]] || {
  echo "FAIL: Groq AI credential was not stored encrypted."
  exit 1
}

echo "PASS: dedicated Groq AI credential imported into encrypted n8n storage."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }

set -a
source "$ENV_FILE"
set +a

required=(GROQ_API_KEY N8N_DB_USER N8N_DB_NAME)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

python3 - <<'PY' | "${compose[@]}" run --rm --no-deps -T n8n import:credentials --input=/dev/stdin
import json, os
print(json.dumps([{
  "id": "REVINTGROQ001",
  "name": "REVINT | Groq Intelligence",
  "type": "groqApi",
  "data": {"apiKey": os.environ["GROQ_API_KEY"]},
}], separators=(",", ":")))
PY

credential_state="$("${compose[@]}" exec -T n8n-db   psql -X -q -A -t -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
    SELECT count(*) || '|' ||
           count(*) FILTER (WHERE data NOT LIKE '{%')
    FROM credentials_entity
    WHERE id='REVINTGROQ001'
      AND type='groqApi';
  ")"

[[ "$credential_state" == "1|1" ]] || {
  echo "FAIL: Groq credential was not stored encrypted."
  exit 1
}

echo "PASS: dedicated Agent V2 Groq credential imported into encrypted n8n storage."

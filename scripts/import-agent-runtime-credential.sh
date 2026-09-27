#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
source "$ENV_FILE"
set +a

required=(REPORT_API_KEY N8N_DB_USER N8N_DB_NAME)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

python3 - <<'PY' | docker compose   --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n import:credentials --input=/dev/stdin
import json, os
print(json.dumps([{
  "id": "REVINTREPORTHEADER001",
  "name": "REVINT | Report Header Auth",
  "type": "httpHeaderAuth",
  "data": {"name": "X-Revint-Report-Key", "value": os.environ["REPORT_API_KEY"]},
}], separators=(",", ":")))
PY

credential_state="$(docker compose   --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n-db   psql -X -q -A -t -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
    SELECT count(*) || '|' ||
           count(*) FILTER (WHERE data NOT LIKE '{%')
    FROM credentials_entity
    WHERE id='REVINTREPORTHEADER001';
  ")"

[[ "$credential_state" == "1|1" ]] || {
  echo "FAIL: report API credential was not stored encrypted."
  exit 1
}

echo "PASS: Agent report header credential imported into encrypted n8n storage."

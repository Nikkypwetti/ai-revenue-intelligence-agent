#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }

set -a
source "$ENV_FILE"
set +a

required=(AIRTABLE_PERSONAL_ACCESS_TOKEN N8N_DB_USER N8N_DB_NAME)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || {
    echo "FAIL: $name is missing or placeholder."
    exit 1
  }
done

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

python3 - <<'PY' | "${compose[@]}" run --rm --no-deps -T n8n import:credentials --input=/dev/stdin
import json, os
print(json.dumps([{
  "id":"REVINTAIRTABLE001",
  "name":"REVINT | Airtable Leads RO",
  "type":"airtableTokenApi",
  "data":{"accessToken":os.environ["AIRTABLE_PERSONAL_ACCESS_TOKEN"]}
}],separators=(",",":")))
PY

state="$("${compose[@]}" exec -T n8n-db psql -X -q -A -t \
  -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
    SELECT count(*) || '|' || count(*) FILTER (WHERE data NOT LIKE '{%')
    FROM credentials_entity
    WHERE id='REVINTAIRTABLE001' AND type='airtableTokenApi';
  ")"

[[ "$state" == "1|1" ]] || {
  echo "FAIL: Airtable credential was not stored encrypted."
  exit 1
}

echo "PASS: dedicated Airtable credential imported into encrypted Agent V2 n8n storage."

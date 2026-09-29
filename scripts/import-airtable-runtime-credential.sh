#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${AIRTABLE_PERSONAL_ACCESS_TOKEN:?Missing AIRTABLE_PERSONAL_ACCESS_TOKEN}"
[[ "$AIRTABLE_PERSONAL_ACCESS_TOKEN" != CHANGE_ME* ]] || {
  echo "FAIL: AIRTABLE_PERSONAL_ACCESS_TOKEN is still a placeholder."
  exit 1
}

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

python3 - <<'PY' | "${compose[@]}" run --rm --no-deps -T n8n import:credentials --input=/dev/stdin
import json, os
print(json.dumps([{
  "id":"REVINTAIRTABLE001",
  "name":"REVINT | Airtable Opportunities RO",
  "type":"airtableTokenApi",
  "data":{"accessToken":os.environ["AIRTABLE_PERSONAL_ACCESS_TOKEN"]}
}], separators=(",",":")))
PY

echo "PASS: dedicated Agent V2 Airtable credential imported into encrypted n8n storage."


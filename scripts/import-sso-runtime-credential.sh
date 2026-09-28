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

required=(SSO_INTERNAL_API_KEY N8N_DB_USER N8N_DB_NAME)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* && "${!name}" != "disabled" ]] || {
    echo "FAIL: $name is missing or uses a placeholder."
    exit 1
  }
done

python3 - <<'PY' | docker compose   --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n import:credentials --input=/dev/stdin
import json, os
credential = [{
    "id": "REVINTSSOINTERNAL001",
    "name": "REVINT | SSO Internal Header Auth",
    "type": "httpHeaderAuth",
    "data": {
        "name": "X-Revint-Sso-Internal-Key",
        "value": os.environ["SSO_INTERNAL_API_KEY"],
    },
}]
print(json.dumps(credential, separators=(",", ":")))
PY

credential_state="$(docker compose   --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n-db   psql -X -q -A -t -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
    SELECT count(*) || '|' ||
           count(*) FILTER (WHERE data NOT LIKE '{%')
    FROM credentials_entity
    WHERE id='REVINTSSOINTERNAL001';
  ")"

[[ "$credential_state" == "1|1" ]] || {
  echo "FAIL: SSO internal credential was not stored encrypted."
  exit 1
}

echo "PASS: SSO internal header credential imported into encrypted n8n storage."

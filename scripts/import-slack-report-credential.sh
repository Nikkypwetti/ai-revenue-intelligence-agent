#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
source "$ENV_FILE"
set +a

required=(SLACK_REPORT_ACCESS_TOKEN N8N_DB_USER N8N_DB_NAME)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || {
    echo "FAIL: $name is missing or placeholder."; exit 1;
  }
done

compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

python3 - <<'PY' | "${compose[@]}" run --rm --no-deps -T n8n import:credentials --input=/dev/stdin
import json, os
print(json.dumps([{
  "id":"REVINTSLACKREPORT001",
  "name":"REVINT | Slack Reports",
  "type":"slackApi",
  "data":{"accessToken":os.environ["SLACK_REPORT_ACCESS_TOKEN"]}
}], separators=(",",":")))
PY

state="$("${compose[@]}" exec -T n8n-db psql -X -q -A -t   -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
  SELECT count(*) || '|' || count(*) FILTER (WHERE data NOT LIKE '{%')
  FROM credentials_entity
  WHERE id='REVINTSLACKREPORT001' AND type='slackApi';
")"

[[ "$state" == "1|1" ]] || {
  echo "FAIL: Slack credential was not stored encrypted."; exit 1;
}

echo "PASS: dedicated Agent V2 Slack report credential imported encrypted."

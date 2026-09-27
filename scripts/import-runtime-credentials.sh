#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL: $ENV_FILE does not exist."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  REPORTING_DB_NAME
  REPORTING_DB_READER_USER REPORTING_DB_READER_PASSWORD
  AUDIT_DB_WRITER_USER AUDIT_DB_WRITER_PASSWORD
  CONNECTOR_DB_WRITER_USER CONNECTOR_DB_WRITER_PASSWORD
  REST_INGEST_API_KEY N8N_DB_USER N8N_DB_NAME
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

python3 - <<'PY' | docker compose   --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n   n8n import:credentials --input=/dev/stdin
import json
import os

def pg(credential_id, name, user_key, password_key):
    return {
        "id": credential_id,
        "name": name,
        "type": "postgres",
        "data": {
            "host": "reporting-db",
            "database": os.environ["REPORTING_DB_NAME"],
            "user": os.environ[user_key],
            "password": os.environ[password_key],
            "port": 5432,
            "ssl": "disable",
            "allowUnauthorizedCerts": False,
            "maxConnections": 5,
        },
    }

credentials = [
    pg(
        "REVINTPGREPORTRO001",
        "REVINT | Reporting RO",
        "REPORTING_DB_READER_USER",
        "REPORTING_DB_READER_PASSWORD",
    ),
    pg(
        "REVINTPGAUDITWR001",
        "REVINT | Audit Writer",
        "AUDIT_DB_WRITER_USER",
        "AUDIT_DB_WRITER_PASSWORD",
    ),
    pg(
        "REVINTPGINGESTWR001",
        "REVINT | Connector Writer",
        "CONNECTOR_DB_WRITER_USER",
        "CONNECTOR_DB_WRITER_PASSWORD",
    ),
    {
        "id": "REVINTRESTHEADER001",
        "name": "REVINT | Ingestion Header Auth",
        "type": "httpHeaderAuth",
        "data": {
            "name": "X-Revint-Ingest-Key",
            "value": os.environ["REST_INGEST_API_KEY"],
        },
    },
]

print(json.dumps(credentials, separators=(",", ":")))
PY
credential_state="$(docker compose   --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T n8n-db   psql -X -q -A -t -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
    SELECT count(*) || '|' ||
           count(*) FILTER (WHERE data NOT LIKE '{%')
    FROM credentials_entity
    WHERE id IN (
      'REVINTPGREPORTRO001',
      'REVINTPGAUDITWR001',
      'REVINTPGINGESTWR001',
      'REVINTRESTHEADER001'
    );
  ")"

[[ "$credential_state" == "4|4" ]] || {
  echo "FAIL: Stage 4 credentials were not stored encrypted."
  exit 1
}

echo "PASS: four Stage 4 runtime credentials imported into encrypted n8n storage."

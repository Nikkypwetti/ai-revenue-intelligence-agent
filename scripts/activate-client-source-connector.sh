#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
provider="${1:-}"
confirm="${2:-}"

case "$provider" in
  salesforce)
    connector="salesforce_primary"
    component="salesforce_sync"
    credential_id="REVINTSALESFORCERO001"
    credential_type="salesforceOAuth2Api"
    ;;
  airtable)
    connector="airtable_primary"
    component="airtable_sync"
    credential_id="REVINTAIRTABLE001"
    credential_type="airtableTokenApi"
    ;;
  *)
    echo "Usage: $0 {salesforce|airtable} REVINT_ACTIVATE_SOURCE"
    exit 1
    ;;
esac

[[ "$confirm" == "REVINT_ACTIVATE_SOURCE" ]] || {
  echo "FAIL: explicit activation confirmation required."
  exit 1
}

set -a
source "$ENV_FILE"
set +a
compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

credential_count="$("${compose[@]}" exec -T n8n-db psql -X -q -A -t   -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c "
SELECT count(*) FROM credentials_entity
WHERE id='$credential_id' AND type='$credential_type';")"
[[ "$credential_count" == "1" ]] || {
  echo "FAIL: dedicated $provider credential is not present in Agent V2."
  exit 1
}

if [[ "$provider" == "airtable" ]]; then
  echo "FAIL: Airtable activation remains blocked until its monthly API billing limit clears and a live read test passes."
  exit 1
fi

"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
UPDATE governance.connector_runtime_config
SET provider_available=true,credential_validated=true,read_enabled=true,
    write_enabled=false,blocked_reason=NULL,updated_at=now()
WHERE connector_key='$connector';
UPDATE governance.connector_registry
SET active=true,updated_at=now()
WHERE connector_key='$connector';
UPDATE governance.reliability_policy
SET active=true,updated_at=now()
WHERE component_key='$component';" >/dev/null

echo "PASS: $provider read-only source connector activated."
echo "NOTE: run a controlled manual sync and connector verification immediately."


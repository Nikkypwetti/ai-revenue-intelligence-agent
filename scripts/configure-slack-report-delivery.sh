#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
DESTINATION_KEY=""
CHANNEL_ID=""
DISPLAY_NAME=""
ENABLE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination-key) DESTINATION_KEY="${2:-}"; shift 2 ;;
    --channel-id) CHANNEL_ID="${2:-}"; shift 2 ;;
    --display-name) DISPLAY_NAME="${2:-}"; shift 2 ;;
    --enable) ENABLE="true"; shift ;;
    *) echo "FAIL: unknown argument $1"; exit 1 ;;
  esac
done

[[ "$DESTINATION_KEY" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || { echo "FAIL: invalid destination key."; exit 1; }
[[ -n "$CHANNEL_ID" && ${#CHANNEL_ID} -le 200 ]] || { echo "FAIL: invalid Slack channel ID."; exit 1; }
[[ -n "$DISPLAY_NAME" && ${#DISPLAY_NAME} -le 200 ]] || { echo "FAIL: invalid display name."; exit 1; }

set -a
source "$ENV_FILE"
set +a
compose=(docker compose -p "${COMPOSE_PROJECT_NAME:-revint-agent}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

tenant="$("${compose[@]}" exec -T reporting-db psql -X -q -A -t -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "SELECT tenant_key FROM governance.deployment_security_config WHERE config_id=1;")"
[[ -n "$tenant" ]] || { echo "FAIL: active deployment tenant not configured."; exit 1; }
esc_key="${DESTINATION_KEY//\'/\'\'}"
esc_id="${CHANNEL_ID//\'/\'\'}"
esc_name="${DISPLAY_NAME//\'/\'\'}"

"${compose[@]}" exec -T reporting-db psql -X -q -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c "
BEGIN;
UPDATE governance.delivery_adapter_config
SET tenant_key='$tenant', slack_report_enabled=false, updated_at=now()
WHERE config_id=1;

UPDATE governance.delivery_destination_registry
SET active=false,updated_at=now()
WHERE tenant_key='$tenant' AND provider_key='slack'
  AND purpose_key='manager_report';

INSERT INTO governance.delivery_destination_registry(
  destination_key,tenant_key,provider_key,purpose_key,
  external_destination_id,display_name,active
) VALUES (
  '$esc_key','$tenant','slack','manager_report',
  '$esc_id','$esc_name',true
)
ON CONFLICT (destination_key) DO UPDATE SET
  tenant_key=EXCLUDED.tenant_key,
  provider_key=EXCLUDED.provider_key,
  purpose_key=EXCLUDED.purpose_key,
  external_destination_id=EXCLUDED.external_destination_id,
  display_name=EXCLUDED.display_name,
  active=true,
  updated_at=now();

UPDATE governance.delivery_adapter_config
SET slack_report_enabled=$ENABLE,updated_at=now()
WHERE config_id=1;

UPDATE governance.reliability_policy
SET active=$ENABLE,updated_at=now()
WHERE component_key='slack_delivery';
COMMIT;"

echo "PASS: Slack report destination configured for tenant $tenant."
echo "Slack report enabled: $ENABLE"

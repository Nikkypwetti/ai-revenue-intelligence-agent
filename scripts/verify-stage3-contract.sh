#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  REPORTING_DB_ADMIN_USER REPORTING_DB_NAME
  REPORTING_DB_READER_USER REPORTING_DB_READER_PASSWORD
  CONNECTOR_DB_WRITER_USER CONNECTOR_DB_WRITER_PASSWORD
  CLIENT_CURRENCY
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

for role_name in "$REPORTING_DB_READER_USER" "$CONNECTOR_DB_WRITER_USER"; do
  [[ "$role_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "FAIL: invalid PostgreSQL role name: $role_name"
    exit 1
  }
done

psql_admin() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_ADMIN_USER" \
    -d "$REPORTING_DB_NAME" \
    "$@"
}

psql_reader() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T \
    -e PGPASSWORD="$REPORTING_DB_READER_PASSWORD" reporting-db \
    psql -h 127.0.0.1 -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_READER_USER" \
    -d "$REPORTING_DB_NAME" \
    "$@"
}

psql_writer() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T \
    -e PGPASSWORD="$CONNECTOR_DB_WRITER_PASSWORD" reporting-db \
    psql -h 127.0.0.1 -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$CONNECTOR_DB_WRITER_USER" \
    -d "$REPORTING_DB_NAME" \
    "$@"
}

ingest_payload() {
  local connector_key="$1"
  local source_record_id="$2"
  local payload="$3"

  psql_writer \
    -v c="$connector_key" \
    -v r="$source_record_id" \
    -v p="$payload" <<'SQL'
SELECT ingestion_status
FROM ingestion.ingest_deal_from_source(:'c', :'r', :'p'::jsonb);
SQL
}

test_hubspot="stage3_hubspot_test"
test_salesforce="stage3_salesforce_test"
tmp_config="$(mktemp)"

cleanup() {
  psql_admin -c "
    DELETE FROM reporting.deals
    WHERE connector_key IN ('$test_hubspot','$test_salesforce');
    DELETE FROM governance.connector_registry
    WHERE connector_key IN ('$test_hubspot','$test_salesforce');
  " >/dev/null 2>&1 || true
  rm -f "$tmp_config"
}
trap cleanup EXIT

cat > "$tmp_config" <<JSON
{
  "schema_version": 1,
  "connectors": [
    {
      "connector_key": "$test_hubspot",
      "connector_type": "hubspot",
      "display_name": "Stage 3 HubSpot Fixture",
      "object_type": "deal",
      "contract_version": 1,
      "active": true,
      "field_mappings": [
        {"canonical_field":"deal_name","source_field":"dealname","transform_key":"text"},
        {"canonical_field":"amount","source_field":"amount","transform_key":"numeric","required":true},
        {"canonical_field":"currency_code","source_field":"currency","transform_key":"uppercase","required":true},
        {"canonical_field":"stage_name","source_field":"dealstage","transform_key":"text","required":true},
        {"canonical_field":"stage_category","source_field":"dealstage","transform_key":"value_map","required":true},
        {"canonical_field":"expected_close_date","source_field":"closedate","transform_key":"timestamp"},
        {"canonical_field":"closed_at","source_field":"closedate","transform_key":"timestamp"}
      ],
      "value_mappings": [
        {"canonical_field":"stage_category","source_value":"closedwon","canonical_value":"won"},
        {"canonical_field":"stage_category","source_value":"closedlost","canonical_value":"lost"}
      ]
    },
    {
      "connector_key": "$test_salesforce",
      "connector_type": "salesforce",
      "display_name": "Stage 3 Salesforce Fixture",
      "object_type": "deal",
      "contract_version": 1,
      "active": true,
      "field_mappings": [
        {"canonical_field":"deal_name","source_field":"Name","transform_key":"text"},
        {"canonical_field":"amount","source_field":"Amount","transform_key":"numeric","required":true},
        {"canonical_field":"currency_code","source_field":"CurrencyIsoCode","transform_key":"uppercase","required":true},
        {"canonical_field":"stage_name","source_field":"StageName","transform_key":"text","required":true},
        {"canonical_field":"stage_category","source_field":"StageName","transform_key":"value_map","required":true},
        {"canonical_field":"expected_close_date","source_field":"CloseDate","transform_key":"timestamp"},
        {"canonical_field":"closed_at","source_field":"CloseDate","transform_key":"timestamp"}
      ],
      "value_mappings": [
        {"canonical_field":"stage_category","source_value":"Prospecting","canonical_value":"open"},
        {"canonical_field":"stage_category","source_value":"Closed Lost","canonical_value":"lost"},
        {"canonical_field":"stage_category","source_value":"Closed Won","canonical_value":"won"}
      ]
    }
  ]
}
JSON

CONNECTOR_CONFIG_FILE="$tmp_config" bash "$ROOT_DIR/scripts/apply-connector-config.sh" >/dev/null

object_count="$(psql_admin -c "SELECT count(*) FROM governance.connector_registry WHERE connector_key IN ('$test_hubspot','$test_salesforce') AND active;")"
[[ "$object_count" == "2" ]] || { echo "FAIL: fixture connector configuration was not applied."; exit 1; }

mapping_count="$(psql_admin -c "SELECT count(*) FROM governance.connector_field_mapping WHERE connector_key IN ('$test_hubspot','$test_salesforce');")"
[[ "$mapping_count" -ge 14 ]] || { echo "FAIL: connector field mappings are incomplete."; exit 1; }

template_count="$(psql_admin -c "SELECT count(*) FROM governance.query_templates WHERE active;")"
[[ "$template_count" -ge 4 ]] || { echo "FAIL: expected at least four active approved query templates."; exit 1; }

catalogue_template_count="$(psql_admin -c "
  SELECT count(*)
  FROM governance.kpi_catalog k
  JOIN governance.query_templates q ON q.query_key = k.query_key
  WHERE k.active AND q.active;
")"
[[ "$catalogue_template_count" -ge 4 ]] || { echo "FAIL: KPI catalogue query keys do not resolve to approved templates."; exit 1; }

privileges="$(psql_admin -c "SELECT
  has_function_privilege('$CONNECTOR_DB_WRITER_USER','ingestion.ingest_deal_from_source(text,text,jsonb)','EXECUTE')::int,
  has_table_privilege('$CONNECTOR_DB_WRITER_USER','reporting.deals','SELECT')::int,
  has_table_privilege('$CONNECTOR_DB_WRITER_USER','reporting.deals','INSERT')::int,
  has_table_privilege('$CONNECTOR_DB_WRITER_USER','governance.connector_registry','SELECT')::int,
  has_table_privilege('$REPORTING_DB_READER_USER','reporting.deals','SELECT')::int,
  has_table_privilege('$REPORTING_DB_READER_USER','reporting.deals','INSERT')::int;")"

IFS='|' read -r writer_execute writer_select writer_insert writer_governance reader_select reader_insert <<< "$privileges"

[[ "$writer_execute" == "1" ]] || { echo "FAIL: connector writer cannot execute the ingestion gateway."; exit 1; }
[[ "$writer_select" == "0" ]] || { echo "FAIL: connector writer unexpectedly has reporting SELECT access."; exit 1; }
[[ "$writer_insert" == "0" ]] || { echo "FAIL: connector writer unexpectedly has direct reporting INSERT access."; exit 1; }
[[ "$writer_governance" == "0" ]] || { echo "FAIL: connector writer unexpectedly has governance SELECT access."; exit 1; }
[[ "$reader_select" == "1" ]] || { echo "FAIL: reporting reader cannot read canonical deals."; exit 1; }
[[ "$reader_insert" == "0" ]] || { echo "FAIL: reporting reader unexpectedly has canonical deal INSERT access."; exit 1; }

hubspot_payload="{\"dealname\":\"Fixture Won\",\"amount\":\"1200\",\"currency\":\"$CLIENT_CURRENCY\",\"dealstage\":\"closedwon\",\"closedate\":\"2026-09-15T12:00:00Z\"}"
salesforce_lost_payload="{\"Name\":\"Fixture Lost\",\"Amount\":\"800\",\"CurrencyIsoCode\":\"$CLIENT_CURRENCY\",\"StageName\":\"Closed Lost\",\"CloseDate\":\"2026-09-20T00:00:00Z\"}"
salesforce_open_payload="{\"Name\":\"Fixture Open\",\"Amount\":\"2000\",\"CurrencyIsoCode\":\"$CLIENT_CURRENCY\",\"StageName\":\"Prospecting\",\"CloseDate\":\"2026-10-15T00:00:00Z\"}"

ingest_payload "$test_hubspot" "hs-001" "$hubspot_payload" >/dev/null

ingest_payload "$test_salesforce" "sf-001" "$salesforce_lost_payload" >/dev/null

ingest_payload "$test_salesforce" "sf-002" "$salesforce_open_payload" >/dev/null

canonical_rows="$(psql_reader -c "
  SELECT count(*)
  FROM reporting.deals
  WHERE connector_key IN ('$test_hubspot','$test_salesforce');
")"
[[ "$canonical_rows" == "3" ]] || { echo "FAIL: expected three canonical fixture deals."; exit 1; }

open_closed_at="$(psql_reader -c "
  SELECT COALESCE(closed_at::text,'NULL')
  FROM reporting.deals
  WHERE connector_key='$test_salesforce' AND source_record_id='sf-002';
")"
[[ "$open_closed_at" == "NULL" ]] || { echo "FAIL: open deal retained a closed_at timestamp."; exit 1; }

hubspot_payload_updated="{\"dealname\":\"Fixture Won\",\"amount\":\"1500\",\"currency\":\"$CLIENT_CURRENCY\",\"dealstage\":\"closedwon\",\"closedate\":\"2026-09-15T12:00:00Z\"}"
ingest_payload "$test_hubspot" "hs-001" "$hubspot_payload_updated" >/dev/null

idempotency_check="$(psql_reader -c "
  SELECT count(*) || '|' || max(amount)::text
  FROM reporting.deals
  WHERE connector_key='$test_hubspot' AND source_record_id='hs-001';
")"
[[ "$idempotency_check" == "1|1500.00" ]] || { echo "FAIL: source-record upsert is not idempotent."; exit 1; }

invalid_stage="{\"Name\":\"Bad Stage\",\"Amount\":\"10\",\"CurrencyIsoCode\":\"$CLIENT_CURRENCY\",\"StageName\":\"Unknown Stage\",\"CloseDate\":\"2026-10-15T00:00:00Z\"}"
if ingest_payload "$test_salesforce" "sf-bad" "$invalid_stage" >/dev/null 2>&1; then
  echo "FAIL: unmapped source stage was accepted."
  exit 1
fi

if psql_writer -c "SELECT count(*) FROM reporting.deals;" >/dev/null 2>&1; then
  echo "FAIL: connector writer bypassed the ingestion gateway and read reporting data."
  exit 1
fi

if psql_writer -c "INSERT INTO reporting.deals (connector_key,source_record_id,amount,currency_code,stage_name,stage_category,source_payload_hash) VALUES ('$test_hubspot','direct-write',1,'$CLIENT_CURRENCY','x','open','x');" >/dev/null 2>&1; then
  echo "FAIL: connector writer bypassed the ingestion gateway and wrote reporting data directly."
  exit 1
fi

if psql_reader -c "DELETE FROM reporting.deals WHERE connector_key='$test_hubspot';" >/dev/null 2>&1; then
  echo "FAIL: reporting reader unexpectedly modified canonical reporting data."
  exit 1
fi

closed_won_revenue="$(psql_reader -c "
  SELECT COALESCE(SUM(amount),0)::numeric(18,2)
  FROM reporting.deals
  WHERE stage_category='won'
    AND closed_at >= '2026-09-01T00:00:00Z'
    AND closed_at < '2026-10-01T00:00:00Z'
    AND connector_key IN ('$test_hubspot','$test_salesforce');
")"
[[ "$closed_won_revenue" == "1500.00" ]] || { echo "FAIL: canonical closed-won revenue result is incorrect."; exit 1; }

win_rate="$(psql_reader -c "
  SELECT ROUND(
    100.0 * COUNT(*) FILTER (WHERE stage_category='won')
    / NULLIF(COUNT(*) FILTER (WHERE stage_category IN ('won','lost')),0),
    2
  )
  FROM reporting.deals
  WHERE closed_at >= '2026-09-01T00:00:00Z'
    AND closed_at < '2026-10-01T00:00:00Z'
    AND connector_key IN ('$test_hubspot','$test_salesforce');
")"
[[ "$win_rate" == "50.00" ]] || { echo "FAIL: canonical win-rate result is incorrect."; exit 1; }

echo "PASS: connector configuration maps two CRM source shapes into one canonical deal contract."
echo "PASS: source-record ingestion is idempotent and rejects unmapped stage values."
echo "PASS: connector writer can only execute the controlled ingestion gateway."
echo "PASS: reporting reader can read canonical deals but cannot modify them."
echo "PASS: all four active KPI query keys resolve to approved deterministic templates."
echo "PASS: canonical fixture KPIs returned expected revenue and win-rate results."

bash "$ROOT_DIR/scripts/verify-stage2-security.sh"
bash "$ROOT_DIR/scripts/healthcheck.sh"

echo "PASS: Stage 3 connector and data-contract verification passed."

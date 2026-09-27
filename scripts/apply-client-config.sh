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
  CLIENT_COMPANY_NAME CLIENT_TIMEZONE CLIENT_CURRENCY
  CLIENT_FISCAL_YEAR_START_MONTH CLIENT_STALE_DEAL_DAYS
  CLIENT_MIN_PIPELINE_COVERAGE
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db   psql -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER"   -d "$REPORTING_DB_NAME"   -v company_name="$CLIENT_COMPANY_NAME"   -v timezone="$CLIENT_TIMEZONE"   -v currency="$CLIENT_CURRENCY"   -v fiscal_month="$CLIENT_FISCAL_YEAR_START_MONTH"   -v stale_days="$CLIENT_STALE_DEAL_DAYS"   -v pipeline_coverage="$CLIENT_MIN_PIPELINE_COVERAGE" <<'SQL'
INSERT INTO governance.business_config (
  config_key,
  company_name,
  timezone,
  currency_code,
  fiscal_year_start_month,
  stale_deal_days,
  minimum_pipeline_coverage,
  updated_at
)
VALUES (
  'default',
  :'company_name',
  :'timezone',
  upper(:'currency'),
  :'fiscal_month'::smallint,
  :'stale_days'::integer,
  :'pipeline_coverage'::numeric,
  now()
)
ON CONFLICT (config_key) DO UPDATE SET
  company_name = EXCLUDED.company_name,
  timezone = EXCLUDED.timezone,
  currency_code = EXCLUDED.currency_code,
  fiscal_year_start_month = EXCLUDED.fiscal_year_start_month,
  stale_deal_days = EXCLUDED.stale_deal_days,
  minimum_pipeline_coverage = EXCLUDED.minimum_pipeline_coverage,
  updated_at = now();
SQL

echo "PASS: Client business configuration applied."

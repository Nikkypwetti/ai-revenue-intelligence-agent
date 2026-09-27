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
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" || "${!name}" == CHANGE_ME* ]]; then
    echo "FAIL: $name is missing or still uses a placeholder."
    exit 1
  fi
done

psql_admin() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" "$@"
}

psql_reader() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T \
    -e PGPASSWORD="$REPORTING_DB_READER_PASSWORD" reporting-db \
    psql -X -q -A -t -v ON_ERROR_STOP=1 \
    -U "$REPORTING_DB_READER_USER" -d "$REPORTING_DB_NAME" "$@"
}

semantic_counts="$(psql_admin -c "
  SELECT
    (SELECT count(*) FROM governance.dimension_catalog WHERE active) || '|' ||
    (SELECT count(*) FROM governance.date_field_catalog WHERE active) || '|' ||
    (SELECT count(*) FROM governance.filter_catalog WHERE active) || '|' ||
    (SELECT count(*) FROM governance.kpi_catalog
      WHERE active
        AND calculation_type IS NOT NULL
        AND formula_expression IS NOT NULL);
")"
[[ "$semantic_counts" == "3|3|4|4" ]] || {
  echo "FAIL: semantic catalog counts are not 3 dimensions, 3 date fields, 4 filters, 4 formulas."
  exit 1
}

mapping_state="$(psql_admin -c "
  SELECT
    (SELECT canonical_column FROM governance.dimension_catalog
      WHERE dimension_key='deal_stage') || '|' ||
    (SELECT canonical_column FROM governance.date_field_catalog
      WHERE date_field_key='closed_date') || '|' ||
    (SELECT canonical_column FROM governance.date_field_catalog
      WHERE date_field_key='expected_close_date');
")"
[[ "$mapping_state" == "stage_name|closed_at|expected_close_date" ]] || {
  echo "FAIL: semantic field mappings do not match the canonical deal contract."
  exit 1
}

dimension_drift="$(psql_admin -c "
  WITH expected AS (
    SELECT k.kpi_key, k.version, u.dimension_key
    FROM governance.kpi_catalog k
    CROSS JOIN LATERAL unnest(k.allowed_dimensions) u(dimension_key)
  ),
  actual AS (
    SELECT kpi_key, kpi_version AS version, dimension_key
    FROM governance.kpi_dimension_policy
  )
  SELECT
    (SELECT count(*) FROM (SELECT * FROM expected EXCEPT SELECT * FROM actual) x)
    +
    (SELECT count(*) FROM (SELECT * FROM actual EXCEPT SELECT * FROM expected) y);
")"
[[ "$dimension_drift" == "0" ]] || {
  echo "FAIL: KPI dimension policy drift detected."
  exit 1
}

filter_drift="$(psql_admin -c "
  WITH expected AS (
    SELECT k.kpi_key, k.version, u.filter_key
    FROM governance.kpi_catalog k
    CROSS JOIN LATERAL unnest(k.allowed_filters) u(filter_key)
  ),
  actual AS (
    SELECT kpi_key, kpi_version AS version, filter_key
    FROM governance.kpi_filter_policy
  )
  SELECT
    (SELECT count(*) FROM (SELECT * FROM expected EXCEPT SELECT * FROM actual) x)
    +
    (SELECT count(*) FROM (SELECT * FROM actual EXCEPT SELECT * FROM expected) y);
")"
[[ "$filter_drift" == "0" ]] || {
  echo "FAIL: KPI filter policy drift detected."
  exit 1
}

contract_count="$(psql_admin -c "
  SELECT count(*)
  FROM governance.kpi_catalog k
  JOIN governance.query_templates q
    ON q.query_key=k.query_key AND q.active
  JOIN governance.date_field_catalog d
    ON d.date_field_key=k.default_date_field AND d.active
  WHERE k.active
    AND k.calculation_type IS NOT NULL
    AND k.formula_expression IS NOT NULL;
")"
[[ "$contract_count" == "4" ]] || {
  echo "FAIL: active KPIs do not fully resolve to query/date/formula contracts."
  exit 1
}

resolved_count="$(psql_admin -c "
  SELECT count(*)
  FROM (
    SELECT *
    FROM governance.resolve_kpi_semantics('closed_won_revenue',NULL)
    UNION ALL
    SELECT * FROM governance.resolve_kpi_semantics('open_pipeline',NULL)
    UNION ALL
    SELECT * FROM governance.resolve_kpi_semantics('closed_won_deals',NULL)
    UNION ALL
    SELECT * FROM governance.resolve_kpi_semantics('win_rate',NULL)
  ) s;
")"
[[ "$resolved_count" == "4" ]] || {
  echo "FAIL: deterministic KPI semantic resolver did not resolve all four KPIs."
  exit 1
}

resolver_state="$(psql_admin -c "
  SELECT calculation_type || '|' || default_date_column || '|' ||
         array_to_string(allowed_dimensions,',') || '|' ||
         array_to_string(allowed_filters,',')
  FROM governance.resolve_kpi_semantics('open_pipeline',1);
")"
[[ "$resolver_state" == "sum|expected_close_date|deal_stage,lead_source,sales_rep|date_range,deal_stage,lead_source,sales_rep" ]] || {
  echo "FAIL: open_pipeline semantic resolution is not deterministic."
  exit 1
}

permission_state="$(psql_admin -c "
  SELECT
    has_table_privilege('$REPORTING_DB_READER_USER','governance.dimension_catalog','SELECT')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','governance.filter_catalog','SELECT')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','governance.kpi_dimension_policy','SELECT')::int || '|' ||
    has_function_privilege('$REPORTING_DB_READER_USER','governance.resolve_kpi_semantics(text,integer)','EXECUTE')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','governance.dimension_catalog','INSERT')::int;
")"
[[ "$permission_state" == "1|1|1|1|0" ]] || {
  echo "FAIL: reporting-reader semantic-layer privileges are not read-only."
  exit 1
}

reader_result="$(psql_reader -c "
  SELECT kpi_key || '|' || query_key
  FROM governance.resolve_kpi_semantics('closed_won_revenue',1);
")"
[[ "$reader_result" == "closed_won_revenue|closed_won_revenue_v1" ]] || {
  echo "FAIL: reporting reader cannot resolve approved KPI semantics."
  exit 1
}

psql_admin <<'SQL' >/dev/null
DO $$
BEGIN
  BEGIN
    UPDATE governance.kpi_catalog
    SET allowed_dimensions = array_append(allowed_dimensions, 'arbitrary_sql_field')
    WHERE kpi_key='closed_won_revenue' AND version=1;
    RAISE EXCEPTION 'EXPECTED_UNAPPROVED_DIMENSION_REJECTION';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE 'UNAPPROVED_DIMENSION:%' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    UPDATE governance.kpi_catalog
    SET allowed_filters = array_append(allowed_filters, 'arbitrary_filter')
    WHERE kpi_key='closed_won_revenue' AND version=1;
    RAISE EXCEPTION 'EXPECTED_UNAPPROVED_FILTER_REJECTION';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE 'UNAPPROVED_FILTER:%' THEN
        RAISE;
      END IF;
  END;
END
$$;
SQL

echo "PASS: four KPI formulas resolve through active approved query templates."
echo "PASS: semantic dimensions, filters, and date fields map to canonical columns."
echo "PASS: normalized KPI policies match the existing allowed dimension/filter arrays."
echo "PASS: reporting reader can resolve semantic metadata but cannot modify it."
echo "PASS: unapproved dimensions and filters are rejected deterministically."

bash "$ROOT_DIR/scripts/verify-stage4-runtime.sh"

echo "PASS: KPI semantic-layer verification passed."

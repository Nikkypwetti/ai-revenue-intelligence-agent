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

cleanup() {
  psql_admin -c "
    DELETE FROM governance.role_assignment
    WHERE principal_key LIKE 'verify-%';

    DELETE FROM governance.department_membership
    WHERE principal_key LIKE 'verify-%';

    DELETE FROM governance.principal_registry
    WHERE principal_key LIKE 'verify-%';

    DELETE FROM governance.department_catalog
    WHERE department_key LIKE 'verify-%';

    DELETE FROM governance.role_policy
    WHERE role_key='verify_pipeline_only';
  " >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

role_state="$(psql_admin -c "
  SELECT string_agg(
    role_key || ':' || data_scope || ':' || max_rows,
    ',' ORDER BY role_key
  )
  FROM governance.role_policy
  WHERE role_key IN ('revenue_admin','revenue_manager','sales_rep')
    AND active;
")"
[[ "$role_state" == "revenue_admin:all:1000,revenue_manager:department:500,sales_rep:own:250" ]] || {
  echo "FAIL: baseline role policies are missing or incorrect."
  exit 1
}

role_compat="$(psql_admin -c "
  SELECT string_agg(
    role_key || ':' || can_view_all_teams::text,
    ',' ORDER BY role_key
  )
  FROM governance.role_policy
  WHERE role_key IN ('revenue_admin','revenue_manager','sales_rep');
")"
[[ "$role_compat" == "revenue_admin:true,revenue_manager:false,sales_rep:false" ]] || {
  echo "FAIL: legacy can_view_all_teams compatibility is inconsistent."
  exit 1
}

psql_admin <<'SQL' >/dev/null
INSERT INTO governance.department_catalog (
  department_key, display_name, active
)
VALUES
  ('verify-sales','Verification Sales',true),
  ('verify-enterprise','Verification Enterprise',true);

INSERT INTO governance.principal_registry (
  principal_key, display_name, identity_provider,
  external_subject, canonical_sales_rep, active
)
VALUES
  ('verify-rep-a','Verification Rep A','test','rep-a','Rep A',true),
  ('verify-rep-b','Verification Rep B','test','rep-b','Rep B',true),
  ('verify-manager','Verification Manager','test','manager',NULL,true),
  ('verify-admin','Verification Admin','test','admin',NULL,true),
  ('verify-unmapped','Verification Unmapped Rep','test','unmapped',NULL,true),
  ('verify-restricted','Verification Restricted','test','restricted','Rep Restricted',true);

INSERT INTO governance.department_membership (
  principal_key, department_key, is_primary
)
VALUES
  ('verify-rep-a','verify-sales',true),
  ('verify-rep-b','verify-sales',true),
  ('verify-manager','verify-sales',true),
  ('verify-unmapped','verify-sales',true),
  ('verify-restricted','verify-enterprise',true);

INSERT INTO governance.role_policy (
  role_key, allowed_kpis, allowed_dimensions, allowed_filters,
  max_rows, can_view_all_teams, data_scope, active
)
VALUES (
  'verify_pipeline_only',
  ARRAY['open_pipeline'],
  ARRAY['deal_stage','lead_source','sales_rep'],
  ARRAY['date_range','deal_stage','lead_source','sales_rep'],
  100,
  false,
  'own',
  true
);

INSERT INTO governance.role_assignment (principal_key, role_key)
VALUES
  ('verify-rep-a','sales_rep'),
  ('verify-rep-b','sales_rep'),
  ('verify-manager','revenue_manager'),
  ('verify-admin','revenue_admin'),
  ('verify-unmapped','sales_rep'),
  ('verify-restricted','verify_pipeline_only');
SQL

rep_auth="$(psql_admin -c "
  SELECT allowed::int || '|' || reason || '|' || data_scope || '|' ||
         scope_filter_column || '|' || array_to_string(scope_values,',') || '|' || max_rows
  FROM governance.authorize_kpi_request(
    'verify-rep-a',
    'open_pipeline',
    ARRAY['deal_stage'],
    ARRAY['date_range']
  );
")"
[[ "$rep_auth" == "1|AUTHORIZED|own|sales_rep|Rep A|250" ]] || {
  echo "FAIL: own-scope authorization did not resolve correctly."
  exit 1
}

manager_auth="$(psql_admin -c "
  SELECT allowed::int || '|' || reason || '|' || data_scope || '|' ||
         scope_filter_column || '|' || array_to_string(scope_values,',') || '|' || max_rows
  FROM governance.authorize_kpi_request(
    'verify-manager',
    'open_pipeline',
    ARRAY['deal_stage'],
    ARRAY['date_range','sales_rep']
  );
")"
[[ "$manager_auth" == "1|AUTHORIZED|department|sales_rep|Rep A,Rep B|500" ]] || {
  echo "FAIL: department-scope authorization did not resolve correctly."
  exit 1
}

admin_auth="$(psql_admin -c "
  SELECT allowed::int || '|' || reason || '|' || data_scope || '|' ||
         COALESCE(scope_filter_column,'') || '|' ||
         array_to_string(scope_values,',') || '|' || max_rows
  FROM governance.authorize_kpi_request(
    'verify-admin',
    'closed_won_revenue',
    ARRAY['sales_rep'],
    ARRAY['date_range']
  );
")"
[[ "$admin_auth" == "1|AUTHORIZED|all|||1000" ]] || {
  echo "FAIL: all-scope authorization did not resolve correctly."
  exit 1
}

restricted_auth="$(psql_admin -c "
  SELECT allowed::int || '|' || reason
  FROM governance.authorize_kpi_request(
    'verify-restricted',
    'win_rate',
    ARRAY[]::text[],
    ARRAY['date_range']
  );
")"
[[ "$restricted_auth" == "0|KPI_NOT_ALLOWED" ]] || {
  echo "FAIL: role-level KPI restriction was not enforced."
  exit 1
}

unmapped_auth="$(psql_admin -c "
  SELECT allowed::int || '|' || reason
  FROM governance.authorize_kpi_request(
    'verify-unmapped',
    'open_pipeline',
    ARRAY[]::text[],
    ARRAY['date_range']
  );
")"
[[ "$unmapped_auth" == "0|OWN_SCOPE_IDENTITY_UNMAPPED" ]] || {
  echo "FAIL: own-scope principal without a sales-rep mapping was not denied."
  exit 1
}

invalid_dimension="$(psql_admin -c "
  SELECT allowed::int || '|' || reason
  FROM governance.authorize_kpi_request(
    'verify-rep-a',
    'open_pipeline',
    ARRAY['currency_code'],
    ARRAY['date_range']
  );
")"
[[ "$invalid_dimension" == "0|KPI_DIMENSION_NOT_ALLOWED" ]] || {
  echo "FAIL: unsupported KPI dimension was not rejected."
  exit 1
}

permission_state="$(psql_admin -c "
  SELECT
    has_table_privilege('$REPORTING_DB_READER_USER','governance.department_catalog','SELECT')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','governance.principal_registry','SELECT')::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','governance.role_assignment','SELECT')::int || '|' ||
    has_function_privilege(
      '$REPORTING_DB_READER_USER',
      'governance.authorize_kpi_request(text,text,text[],text[])',
      'EXECUTE'
    )::int || '|' ||
    has_table_privilege('$REPORTING_DB_READER_USER','governance.principal_registry','INSERT')::int;
")"
[[ "$permission_state" == "1|0|0|1|0" ]] || {
  echo "FAIL: identity-table least-privilege boundary is incorrect."
  exit 1
}

reader_auth="$(psql_reader -c "
  SELECT allowed::int || '|' || reason || '|' || data_scope
  FROM governance.authorize_kpi_request(
    'verify-rep-a',
    'open_pipeline',
    ARRAY[]::text[],
    ARRAY['date_range']
  );
")"
[[ "$reader_auth" == "1|AUTHORIZED|own" ]] || {
  echo "FAIL: reporting reader cannot use the bounded authorization gateway."
  exit 1
}

psql_admin <<'SQL' >/dev/null
DO $$
BEGIN
  BEGIN
    INSERT INTO governance.role_policy (
      role_key, allowed_kpis, allowed_dimensions, allowed_filters,
      max_rows, can_view_all_teams, data_scope, active
    )
    VALUES (
      'verify-invalid-role',
      ARRAY['arbitrary_kpi'],
      ARRAY[]::text[],
      ARRAY[]::text[],
      10,
      false,
      'own',
      true
    );
    RAISE EXCEPTION 'EXPECTED_INVALID_ROLE_KPI_REJECTION';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE 'UNAPPROVED_ROLE_KPI:%' THEN
        RAISE;
      END IF;
  END;
END
$$;
SQL

echo "PASS: baseline roles provide all, department, and own data scopes."
echo "PASS: principal roles and department memberships resolve deterministically."
echo "PASS: KPI, dimension, and filter authorization is enforced before query execution."
echo "PASS: department scope resolves to canonical sales_rep values."
echo "PASS: reporting reader can call authorization but cannot read identity tables."
echo "PASS: invalid role policies are rejected by semantic governance."

bash "$ROOT_DIR/scripts/verify-semantic-layer.sh"

echo "PASS: identity and permission verification passed."

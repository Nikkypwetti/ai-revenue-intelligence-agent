\set ON_ERROR_STOP on

ALTER TABLE governance.role_policy
  ADD COLUMN IF NOT EXISTS allowed_filters text[] NOT NULL DEFAULT '{}';

ALTER TABLE governance.role_policy
  ADD COLUMN IF NOT EXISTS data_scope text;

ALTER TABLE governance.role_policy
  ADD COLUMN IF NOT EXISTS active boolean NOT NULL DEFAULT true;

UPDATE governance.role_policy
SET data_scope = CASE
  WHEN can_view_all_teams THEN 'all'
  ELSE 'own'
END
WHERE data_scope IS NULL;

ALTER TABLE governance.role_policy
  ALTER COLUMN data_scope SET DEFAULT 'own';

ALTER TABLE governance.role_policy
  ALTER COLUMN data_scope SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'role_policy_data_scope_check'
      AND conrelid = 'governance.role_policy'::regclass
  ) THEN
    ALTER TABLE governance.role_policy
      ADD CONSTRAINT role_policy_data_scope_check
      CHECK (data_scope IN ('own','department','all'));
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS governance.department_catalog (
  department_key text PRIMARY KEY,
  display_name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (department_key ~ '^[a-z0-9][a-z0-9_-]{0,63}$')
);

CREATE TABLE IF NOT EXISTS governance.principal_registry (
  principal_key text PRIMARY KEY,
  display_name text NOT NULL,
  identity_provider text NOT NULL DEFAULT 'local',
  external_subject text,
  canonical_sales_rep text,
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (principal_key ~ '^[a-zA-Z0-9][a-zA-Z0-9._:@-]{0,127}$'),
  CHECK (identity_provider ~ '^[a-z0-9][a-z0-9_-]{0,63}$')
);

CREATE UNIQUE INDEX IF NOT EXISTS
  principal_registry_provider_subject_uidx
ON governance.principal_registry(identity_provider, external_subject)
WHERE external_subject IS NOT NULL;

CREATE TABLE IF NOT EXISTS governance.department_membership (
  principal_key text NOT NULL
    REFERENCES governance.principal_registry(principal_key)
    ON DELETE CASCADE,
  department_key text NOT NULL
    REFERENCES governance.department_catalog(department_key),
  is_primary boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (principal_key, department_key)
);

CREATE UNIQUE INDEX IF NOT EXISTS
  department_membership_one_primary_uidx
ON governance.department_membership(principal_key)
WHERE is_primary;

CREATE TABLE IF NOT EXISTS governance.role_assignment (
  principal_key text NOT NULL
    REFERENCES governance.principal_registry(principal_key)
    ON DELETE CASCADE,
  role_key text NOT NULL
    REFERENCES governance.role_policy(role_key)
    ON DELETE CASCADE,
  active boolean NOT NULL DEFAULT true,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (principal_key, role_key)
);

CREATE OR REPLACE FUNCTION governance.validate_role_policy_semantics()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, governance
AS $$
DECLARE
  v_key text;
BEGIN
  SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), '{}'::text[])
  INTO NEW.allowed_kpis
  FROM unnest(COALESCE(NEW.allowed_kpis, '{}'::text[])) AS u(x);

  SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), '{}'::text[])
  INTO NEW.allowed_dimensions
  FROM unnest(COALESCE(NEW.allowed_dimensions, '{}'::text[])) AS u(x);

  SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), '{}'::text[])
  INTO NEW.allowed_filters
  FROM unnest(COALESCE(NEW.allowed_filters, '{}'::text[])) AS u(x);

  FOREACH v_key IN ARRAY NEW.allowed_kpis LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM governance.kpi_catalog
      WHERE kpi_key = v_key
        AND active
    ) THEN
      RAISE EXCEPTION 'UNAPPROVED_ROLE_KPI: %', v_key;
    END IF;
  END LOOP;

  FOREACH v_key IN ARRAY NEW.allowed_dimensions LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM governance.dimension_catalog
      WHERE dimension_key = v_key
        AND active
    ) THEN
      RAISE EXCEPTION 'UNAPPROVED_ROLE_DIMENSION: %', v_key;
    END IF;
  END LOOP;

  FOREACH v_key IN ARRAY NEW.allowed_filters LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM governance.filter_catalog
      WHERE filter_key = v_key
        AND active
    ) THEN
      RAISE EXCEPTION 'UNAPPROVED_ROLE_FILTER: %', v_key;
    END IF;
  END LOOP;

  NEW.can_view_all_teams := (NEW.data_scope = 'all');
  NEW.updated_at := now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_role_policy_semantics
ON governance.role_policy;

CREATE TRIGGER trg_validate_role_policy_semantics
BEFORE INSERT OR UPDATE OF
  allowed_kpis,
  allowed_dimensions,
  allowed_filters,
  data_scope,
  can_view_all_teams
ON governance.role_policy
FOR EACH ROW
EXECUTE FUNCTION governance.validate_role_policy_semantics();

CREATE OR REPLACE FUNCTION governance.resolve_principal_permissions(
  p_principal_key text
)
RETURNS TABLE (
  principal_key text,
  principal_active boolean,
  role_keys text[],
  allowed_kpis text[],
  allowed_dimensions text[],
  allowed_filters text[],
  max_rows integer,
  data_scope text,
  department_keys text[],
  canonical_sales_rep text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
  WITH principal AS (
    SELECT p.*
    FROM governance.principal_registry p
    WHERE p.principal_key = p_principal_key
  ),
  assigned_roles AS (
    SELECT rp.*
    FROM governance.role_assignment ra
    JOIN governance.role_policy rp
      ON rp.role_key = ra.role_key
     AND rp.active
    WHERE ra.principal_key = p_principal_key
      AND ra.active
  )
  SELECT
    p.principal_key,
    p.active,
    COALESCE((
      SELECT array_agg(role_key ORDER BY role_key)
      FROM assigned_roles
    ), '{}'::text[]),
    COALESCE((
      SELECT array_agg(DISTINCT value ORDER BY value)
      FROM assigned_roles ar
      CROSS JOIN LATERAL unnest(ar.allowed_kpis) AS x(value)
    ), '{}'::text[]),
    COALESCE((
      SELECT array_agg(DISTINCT value ORDER BY value)
      FROM assigned_roles ar
      CROSS JOIN LATERAL unnest(ar.allowed_dimensions) AS x(value)
    ), '{}'::text[]),
    COALESCE((
      SELECT array_agg(DISTINCT value ORDER BY value)
      FROM assigned_roles ar
      CROSS JOIN LATERAL unnest(ar.allowed_filters) AS x(value)
    ), '{}'::text[]),
    COALESCE((SELECT max(ar.max_rows) FROM assigned_roles ar), 0),
    COALESCE((
      SELECT CASE max(
        CASE ar.data_scope
          WHEN 'all' THEN 3
          WHEN 'department' THEN 2
          WHEN 'own' THEN 1
          ELSE 0
        END
      )
        WHEN 3 THEN 'all'
        WHEN 2 THEN 'department'
        WHEN 1 THEN 'own'
        ELSE 'none'
      END
      FROM assigned_roles ar
    ), 'none'),
    COALESCE((
      SELECT array_agg(dm.department_key ORDER BY dm.department_key)
      FROM governance.department_membership dm
      JOIN governance.department_catalog d
        ON d.department_key = dm.department_key
       AND d.active
      WHERE dm.principal_key = p_principal_key
    ), '{}'::text[]),
    p.canonical_sales_rep
  FROM principal p;
$$;

CREATE OR REPLACE FUNCTION governance.authorize_kpi_request(
  p_principal_key text,
  p_kpi_key text,
  p_requested_dimensions text[] DEFAULT '{}'::text[],
  p_requested_filters text[] DEFAULT '{}'::text[]
)
RETURNS TABLE (
  allowed boolean,
  reason text,
  max_rows integer,
  data_scope text,
  scope_filter_column text,
  scope_values text[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
DECLARE
  v_permissions record;
  v_semantics record;
  v_dimensions text[] := COALESCE(p_requested_dimensions, '{}'::text[]);
  v_filters text[] := COALESCE(p_requested_filters, '{}'::text[]);
  v_scope_values text[] := '{}'::text[];
BEGIN
  SELECT *
  INTO v_permissions
  FROM governance.resolve_principal_permissions(p_principal_key);

  IF NOT FOUND THEN
    RETURN QUERY
    SELECT false, 'PRINCIPAL_NOT_FOUND', 0, 'none', NULL::text, '{}'::text[];
    RETURN;
  END IF;

  IF NOT v_permissions.principal_active THEN
    RETURN QUERY
    SELECT false, 'PRINCIPAL_INACTIVE', 0, 'none', NULL::text, '{}'::text[];
    RETURN;
  END IF;

  IF cardinality(v_permissions.role_keys) = 0 THEN
    RETURN QUERY
    SELECT false, 'NO_ACTIVE_ROLE', 0, 'none', NULL::text, '{}'::text[];
    RETURN;
  END IF;

  SELECT *
  INTO v_semantics
  FROM governance.resolve_kpi_semantics(p_kpi_key, NULL);

  IF NOT FOUND THEN
    RETURN QUERY
    SELECT false, 'KPI_NOT_APPROVED',
           v_permissions.max_rows, v_permissions.data_scope,
           NULL::text, '{}'::text[];
    RETURN;
  END IF;

  IF NOT (p_kpi_key = ANY(v_permissions.allowed_kpis)) THEN
    RETURN QUERY
    SELECT false, 'KPI_NOT_ALLOWED',
           v_permissions.max_rows, v_permissions.data_scope,
           NULL::text, '{}'::text[];
    RETURN;
  END IF;

  IF array_position(v_dimensions, NULL) IS NOT NULL
     OR NOT (v_dimensions <@ v_semantics.allowed_dimensions) THEN
    RETURN QUERY
    SELECT false, 'KPI_DIMENSION_NOT_ALLOWED',
           v_permissions.max_rows, v_permissions.data_scope,
           NULL::text, '{}'::text[];
    RETURN;
  END IF;

  IF NOT (v_dimensions <@ v_permissions.allowed_dimensions) THEN
    RETURN QUERY
    SELECT false, 'ROLE_DIMENSION_NOT_ALLOWED',
           v_permissions.max_rows, v_permissions.data_scope,
           NULL::text, '{}'::text[];
    RETURN;
  END IF;

  IF array_position(v_filters, NULL) IS NOT NULL
     OR NOT (v_filters <@ v_semantics.allowed_filters) THEN
    RETURN QUERY
    SELECT false, 'KPI_FILTER_NOT_ALLOWED',
           v_permissions.max_rows, v_permissions.data_scope,
           NULL::text, '{}'::text[];
    RETURN;
  END IF;

  IF NOT (v_filters <@ v_permissions.allowed_filters) THEN
    RETURN QUERY
    SELECT false, 'ROLE_FILTER_NOT_ALLOWED',
           v_permissions.max_rows, v_permissions.data_scope,
           NULL::text, '{}'::text[];
    RETURN;
  END IF;

  CASE v_permissions.data_scope
    WHEN 'own' THEN
      IF NULLIF(btrim(COALESCE(v_permissions.canonical_sales_rep, '')), '') IS NULL THEN
        RETURN QUERY
        SELECT false, 'OWN_SCOPE_IDENTITY_UNMAPPED',
               v_permissions.max_rows, 'own',
               'sales_rep', '{}'::text[];
        RETURN;
      END IF;
      v_scope_values := ARRAY[v_permissions.canonical_sales_rep];

    WHEN 'department' THEN
      IF cardinality(v_permissions.department_keys) = 0 THEN
        RETURN QUERY
        SELECT false, 'DEPARTMENT_SCOPE_UNMAPPED',
               v_permissions.max_rows, 'department',
               'sales_rep', '{}'::text[];
        RETURN;
      END IF;

      SELECT COALESCE(array_agg(DISTINCT p.canonical_sales_rep
                                ORDER BY p.canonical_sales_rep), '{}'::text[])
      INTO v_scope_values
      FROM governance.principal_registry p
      JOIN governance.department_membership dm
        ON dm.principal_key = p.principal_key
      WHERE p.active
        AND NULLIF(btrim(COALESCE(p.canonical_sales_rep, '')), '') IS NOT NULL
        AND dm.department_key = ANY(v_permissions.department_keys);

      IF cardinality(v_scope_values) = 0 THEN
        RETURN QUERY
        SELECT false, 'DEPARTMENT_SCOPE_EMPTY',
               v_permissions.max_rows, 'department',
               'sales_rep', '{}'::text[];
        RETURN;
      END IF;

    WHEN 'all' THEN
      v_scope_values := '{}'::text[];

    ELSE
      RETURN QUERY
      SELECT false, 'DATA_SCOPE_NOT_ALLOWED',
             v_permissions.max_rows, v_permissions.data_scope,
             NULL::text, '{}'::text[];
      RETURN;
  END CASE;

  RETURN QUERY
  SELECT true, 'AUTHORIZED',
         v_permissions.max_rows,
         v_permissions.data_scope,
         CASE
           WHEN v_permissions.data_scope IN ('own','department')
             THEN 'sales_rep'
           ELSE NULL
         END,
         v_scope_values;
END;
$$;

REVOKE ALL ON FUNCTION governance.validate_role_policy_semantics()
FROM PUBLIC;

REVOKE ALL ON FUNCTION governance.resolve_principal_permissions(text)
FROM PUBLIC;

REVOKE ALL ON FUNCTION governance.authorize_kpi_request(text,text,text[],text[])
FROM PUBLIC;

GRANT SELECT ON governance.department_catalog
TO revint_governance_ro;

GRANT EXECUTE ON FUNCTION
  governance.authorize_kpi_request(text,text,text[],text[])
TO revint_governance_ro;

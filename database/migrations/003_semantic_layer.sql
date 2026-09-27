\set ON_ERROR_STOP on

ALTER TABLE governance.kpi_catalog
  ADD COLUMN IF NOT EXISTS calculation_type text;

ALTER TABLE governance.kpi_catalog
  ADD COLUMN IF NOT EXISTS formula_expression text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'kpi_catalog_calculation_type_check'
      AND conrelid = 'governance.kpi_catalog'::regclass
  ) THEN
    ALTER TABLE governance.kpi_catalog
      ADD CONSTRAINT kpi_catalog_calculation_type_check
      CHECK (
        calculation_type IS NULL
        OR calculation_type IN ('sum','count','ratio','average')
      );
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS governance.dimension_catalog (
  dimension_key text PRIMARY KEY,
  display_name text NOT NULL,
  description text NOT NULL,
  canonical_column text NOT NULL CHECK (
    canonical_column IN (
      'currency_code','stage_name','stage_category',
      'sales_rep','lead_source'
    )
  ),
  data_type text NOT NULL CHECK (
    data_type IN ('text','category','currency')
  ),
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS governance.date_field_catalog (
  date_field_key text PRIMARY KEY,
  display_name text NOT NULL,
  description text NOT NULL,
  canonical_column text NOT NULL UNIQUE CHECK (
    canonical_column IN (
      'created_at','expected_close_date','closed_at','source_updated_at'
    )
  ),
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS governance.filter_catalog (
  filter_key text PRIMARY KEY,
  display_name text NOT NULL,
  description text NOT NULL,
  filter_kind text NOT NULL CHECK (
    filter_kind IN ('date_range','field')
  ),
  canonical_column text,
  data_type text NOT NULL CHECK (
    data_type IN ('text','category','timestamp')
  ),
  allowed_operators text[] NOT NULL DEFAULT '{}',
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    allowed_operators <@ ARRAY['eq','in','between']::text[]
  ),
  CHECK (
    (filter_kind = 'date_range' AND canonical_column IS NULL)
    OR
    (
      filter_kind = 'field'
      AND canonical_column IN (
        'currency_code','stage_name','stage_category',
        'sales_rep','lead_source'
      )
    )
  )
);

CREATE TABLE IF NOT EXISTS governance.kpi_dimension_policy (
  kpi_key text NOT NULL,
  kpi_version integer NOT NULL,
  dimension_key text NOT NULL
    REFERENCES governance.dimension_catalog(dimension_key),
  PRIMARY KEY (kpi_key, kpi_version, dimension_key),
  FOREIGN KEY (kpi_key, kpi_version)
    REFERENCES governance.kpi_catalog(kpi_key, version)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS governance.kpi_filter_policy (
  kpi_key text NOT NULL,
  kpi_version integer NOT NULL,
  filter_key text NOT NULL
    REFERENCES governance.filter_catalog(filter_key),
  PRIMARY KEY (kpi_key, kpi_version, filter_key),
  FOREIGN KEY (kpi_key, kpi_version)
    REFERENCES governance.kpi_catalog(kpi_key, version)
    ON DELETE CASCADE
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'kpi_catalog_query_key_fk'
      AND conrelid = 'governance.kpi_catalog'::regclass
  ) THEN
    ALTER TABLE governance.kpi_catalog
      ADD CONSTRAINT kpi_catalog_query_key_fk
      FOREIGN KEY (query_key)
      REFERENCES governance.query_templates(query_key);
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION governance.sync_kpi_semantic_policies()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, governance
AS $$
DECLARE
  v_key text;
BEGIN
  DELETE FROM governance.kpi_dimension_policy
  WHERE kpi_key = NEW.kpi_key
    AND kpi_version = NEW.version;

  FOREACH v_key IN ARRAY NEW.allowed_dimensions LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM governance.dimension_catalog
      WHERE dimension_key = v_key
        AND active
    ) THEN
      RAISE EXCEPTION 'UNAPPROVED_DIMENSION: %', v_key;
    END IF;

    INSERT INTO governance.kpi_dimension_policy (
      kpi_key, kpi_version, dimension_key
    )
    VALUES (NEW.kpi_key, NEW.version, v_key);
  END LOOP;

  DELETE FROM governance.kpi_filter_policy
  WHERE kpi_key = NEW.kpi_key
    AND kpi_version = NEW.version;

  FOREACH v_key IN ARRAY NEW.allowed_filters LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM governance.filter_catalog
      WHERE filter_key = v_key
        AND active
    ) THEN
      RAISE EXCEPTION 'UNAPPROVED_FILTER: %', v_key;
    END IF;

    INSERT INTO governance.kpi_filter_policy (
      kpi_key, kpi_version, filter_key
    )
    VALUES (NEW.kpi_key, NEW.version, v_key);
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_kpi_semantic_policies
ON governance.kpi_catalog;

CREATE TRIGGER trg_sync_kpi_semantic_policies
AFTER INSERT OR UPDATE OF allowed_dimensions, allowed_filters
ON governance.kpi_catalog
FOR EACH ROW
EXECUTE FUNCTION governance.sync_kpi_semantic_policies();

CREATE OR REPLACE FUNCTION governance.resolve_kpi_semantics(
  p_kpi_key text,
  p_version integer DEFAULT NULL
)
RETURNS TABLE (
  kpi_key text,
  kpi_version integer,
  display_name text,
  description text,
  unit text,
  calculation_type text,
  formula_expression text,
  query_key text,
  query_version integer,
  result_type text,
  maximum_rows integer,
  default_date_field text,
  default_date_column text,
  allowed_dimensions text[],
  allowed_filters text[]
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, governance
AS $$
  WITH selected AS (
    SELECT k.*
    FROM governance.kpi_catalog k
    WHERE k.kpi_key = p_kpi_key
      AND k.active
      AND k.calculation_type IS NOT NULL
      AND k.formula_expression IS NOT NULL
      AND (p_version IS NULL OR k.version = p_version)
    ORDER BY k.version DESC
    LIMIT 1
  )
  SELECT
    k.kpi_key,
    k.version,
    k.display_name,
    k.description,
    k.unit,
    k.calculation_type,
    k.formula_expression,
    k.query_key,
    q.version,
    q.result_type,
    q.maximum_rows,
    k.default_date_field,
    d.canonical_column,
    COALESCE((
      SELECT array_agg(p.dimension_key ORDER BY p.dimension_key)
      FROM governance.kpi_dimension_policy p
      JOIN governance.dimension_catalog dc
        ON dc.dimension_key = p.dimension_key
       AND dc.active
      WHERE p.kpi_key = k.kpi_key
        AND p.kpi_version = k.version
    ), '{}'::text[]),
    COALESCE((
      SELECT array_agg(p.filter_key ORDER BY p.filter_key)
      FROM governance.kpi_filter_policy p
      JOIN governance.filter_catalog fc
        ON fc.filter_key = p.filter_key
       AND fc.active
      WHERE p.kpi_key = k.kpi_key
        AND p.kpi_version = k.version
    ), '{}'::text[])
  FROM selected k
  JOIN governance.query_templates q
    ON q.query_key = k.query_key
   AND q.active
  JOIN governance.date_field_catalog d
    ON d.date_field_key = k.default_date_field
   AND d.active;
$$;

REVOKE ALL ON FUNCTION governance.sync_kpi_semantic_policies()
FROM PUBLIC;

REVOKE ALL ON FUNCTION governance.resolve_kpi_semantics(text,integer)
FROM PUBLIC;

GRANT SELECT ON
  governance.dimension_catalog,
  governance.date_field_catalog,
  governance.filter_catalog,
  governance.kpi_dimension_policy,
  governance.kpi_filter_policy
TO revint_governance_ro;

GRANT EXECUTE ON FUNCTION governance.resolve_kpi_semantics(text,integer)
TO revint_governance_ro;

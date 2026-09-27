\set ON_ERROR_STOP on

INSERT INTO governance.dimension_catalog (
  dimension_key, display_name, description,
  canonical_column, data_type, active
)
VALUES
  (
    'sales_rep', 'Sales Rep',
    'Deal owner or sales representative in the canonical reporting model.',
    'sales_rep', 'text', true
  ),
  (
    'lead_source', 'Lead Source',
    'Canonical acquisition or lead-source label for a deal.',
    'lead_source', 'category', true
  ),
  (
    'deal_stage', 'Deal Stage',
    'Source deal stage normalized into the canonical stage-name field.',
    'stage_name', 'category', true
  )
ON CONFLICT (dimension_key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  description = EXCLUDED.description,
  canonical_column = EXCLUDED.canonical_column,
  data_type = EXCLUDED.data_type,
  active = EXCLUDED.active,
  updated_at = now();

INSERT INTO governance.date_field_catalog (
  date_field_key, display_name, description,
  canonical_column, active
)
VALUES
  (
    'closed_date', 'Closed Date',
    'Canonical timestamp used for won/lost outcome reporting.',
    'closed_at', true
  ),
  (
    'expected_close_date', 'Expected Close Date',
    'Canonical expected close timestamp used for open-pipeline reporting.',
    'expected_close_date', true
  ),
  (
    'created_date', 'Created Date',
    'Canonical deal creation timestamp.',
    'created_at', true
  )
ON CONFLICT (date_field_key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  description = EXCLUDED.description,
  canonical_column = EXCLUDED.canonical_column,
  active = EXCLUDED.active,
  updated_at = now();

INSERT INTO governance.filter_catalog (
  filter_key, display_name, description, filter_kind,
  canonical_column, data_type, allowed_operators, active
)
VALUES
  (
    'date_range', 'Date Range',
    'Bounded half-open reporting period resolved through the KPI default date field.',
    'date_range', NULL, 'timestamp', ARRAY['between'], true
  ),
  (
    'sales_rep', 'Sales Rep',
    'Exact or set-based filtering by canonical sales representative.',
    'field', 'sales_rep', 'text', ARRAY['eq','in'], true
  ),
  (
    'lead_source', 'Lead Source',
    'Exact or set-based filtering by canonical lead source.',
    'field', 'lead_source', 'category', ARRAY['eq','in'], true
  ),
  (
    'deal_stage', 'Deal Stage',
    'Exact or set-based filtering by canonical deal stage name.',
    'field', 'stage_name', 'category', ARRAY['eq','in'], true
  )
ON CONFLICT (filter_key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  description = EXCLUDED.description,
  filter_kind = EXCLUDED.filter_kind,
  canonical_column = EXCLUDED.canonical_column,
  data_type = EXCLUDED.data_type,
  allowed_operators = EXCLUDED.allowed_operators,
  active = EXCLUDED.active,
  updated_at = now();

UPDATE governance.kpi_catalog
SET
  calculation_type = CASE kpi_key
    WHEN 'closed_won_revenue' THEN 'sum'
    WHEN 'open_pipeline' THEN 'sum'
    WHEN 'closed_won_deals' THEN 'count'
    WHEN 'win_rate' THEN 'ratio'
    ELSE calculation_type
  END,
  formula_expression = CASE kpi_key
    WHEN 'closed_won_revenue'
      THEN 'SUM(amount) WHERE stage_category = won'
    WHEN 'open_pipeline'
      THEN 'SUM(amount) WHERE stage_category = open'
    WHEN 'closed_won_deals'
      THEN 'COUNT(deal_id) WHERE stage_category = won'
    WHEN 'win_rate'
      THEN '100 * won_closed_deals / all_closed_deals'
    ELSE formula_expression
  END
WHERE kpi_key IN (
  'closed_won_revenue',
  'open_pipeline',
  'closed_won_deals',
  'win_rate'
);

INSERT INTO governance.kpi_dimension_policy (
  kpi_key, kpi_version, dimension_key
)
SELECT
  k.kpi_key,
  k.version,
  d.dimension_key
FROM governance.kpi_catalog k
CROSS JOIN LATERAL unnest(k.allowed_dimensions) AS requested(dimension_key)
JOIN governance.dimension_catalog d
  ON d.dimension_key = requested.dimension_key
 AND d.active
ON CONFLICT DO NOTHING;

INSERT INTO governance.kpi_filter_policy (
  kpi_key, kpi_version, filter_key
)
SELECT
  k.kpi_key,
  k.version,
  f.filter_key
FROM governance.kpi_catalog k
CROSS JOIN LATERAL unnest(k.allowed_filters) AS requested(filter_key)
JOIN governance.filter_catalog f
  ON f.filter_key = requested.filter_key
 AND f.active
ON CONFLICT DO NOTHING;

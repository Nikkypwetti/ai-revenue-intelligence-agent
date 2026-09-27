INSERT INTO governance.kpi_catalog (
  kpi_key,
  version,
  display_name,
  description,
  unit,
  query_key,
  default_date_field,
  allowed_dimensions,
  allowed_filters,
  active
)
VALUES
  (
    'closed_won_revenue',
    1,
    'Closed Won Revenue',
    'Sum of approved Closed Won deal value for the requested period.',
    'currency',
    'closed_won_revenue_v1',
    'closed_date',
    ARRAY['sales_rep','lead_source'],
    ARRAY['date_range','sales_rep','lead_source'],
    true
  ),
  (
    'open_pipeline',
    1,
    'Open Pipeline',
    'Sum of currently open opportunity value for the requested period or scope.',
    'currency',
    'open_pipeline_v1',
    'expected_close_date',
    ARRAY['sales_rep','deal_stage','lead_source'],
    ARRAY['date_range','sales_rep','deal_stage','lead_source'],
    true
  ),
  (
    'closed_won_deals',
    1,
    'Closed Won Deals',
    'Count of opportunities with an approved Closed Won outcome.',
    'count',
    'closed_won_deals_v1',
    'closed_date',
    ARRAY['sales_rep','lead_source'],
    ARRAY['date_range','sales_rep','lead_source'],
    true
  ),
  (
    'win_rate',
    1,
    'Win Rate',
    'Closed Won deals divided by all closed deals in the requested period.',
    'percent',
    'win_rate_v1',
    'closed_date',
    ARRAY['sales_rep','lead_source'],
    ARRAY['date_range','sales_rep','lead_source'],
    true
  )
ON CONFLICT (kpi_key, version) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  description = EXCLUDED.description,
  unit = EXCLUDED.unit,
  query_key = EXCLUDED.query_key,
  default_date_field = EXCLUDED.default_date_field,
  allowed_dimensions = EXCLUDED.allowed_dimensions,
  allowed_filters = EXCLUDED.allowed_filters,
  active = EXCLUDED.active;

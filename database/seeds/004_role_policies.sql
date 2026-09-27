\set ON_ERROR_STOP on

INSERT INTO governance.role_policy (
  role_key,
  allowed_kpis,
  allowed_dimensions,
  allowed_filters,
  max_rows,
  can_view_all_teams,
  data_scope,
  active
)
VALUES
  (
    'revenue_admin',
    ARRAY[
      'closed_won_deals',
      'closed_won_revenue',
      'open_pipeline',
      'win_rate'
    ],
    ARRAY['deal_stage','lead_source','sales_rep'],
    ARRAY['date_range','deal_stage','lead_source','sales_rep'],
    1000,
    true,
    'all',
    true
  ),
  (
    'revenue_manager',
    ARRAY[
      'closed_won_deals',
      'closed_won_revenue',
      'open_pipeline',
      'win_rate'
    ],
    ARRAY['deal_stage','lead_source','sales_rep'],
    ARRAY['date_range','deal_stage','lead_source','sales_rep'],
    500,
    false,
    'department',
    true
  ),
  (
    'sales_rep',
    ARRAY[
      'closed_won_deals',
      'closed_won_revenue',
      'open_pipeline',
      'win_rate'
    ],
    ARRAY['deal_stage','lead_source','sales_rep'],
    ARRAY['date_range','deal_stage','lead_source','sales_rep'],
    250,
    false,
    'own',
    true
  )
ON CONFLICT (role_key) DO UPDATE SET
  allowed_kpis = EXCLUDED.allowed_kpis,
  allowed_dimensions = EXCLUDED.allowed_dimensions,
  allowed_filters = EXCLUDED.allowed_filters,
  max_rows = EXCLUDED.max_rows,
  can_view_all_teams = EXCLUDED.can_view_all_teams,
  data_scope = EXCLUDED.data_scope,
  active = EXCLUDED.active;

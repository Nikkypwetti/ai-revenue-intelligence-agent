INSERT INTO governance.query_templates (
  query_key,
  query_name,
  description,
  sql_template,
  allowed_parameters,
  result_type,
  maximum_rows,
  version,
  active
)
VALUES
(
  'closed_won_revenue_v1',
  'Closed Won Revenue v1',
  'Returns closed-won revenue from the canonical deal contract for a bounded period.',
  $sql$
SELECT COALESCE(SUM(amount), 0)::numeric(18,2) AS metric_value
FROM reporting.deals
WHERE stage_category = 'won'
  AND closed_at >= $1::timestamptz
  AND closed_at < $2::timestamptz
$sql$,
  ARRAY['start_at','end_at'],
  'scalar',
  1,
  1,
  true
),
(
  'open_pipeline_v1',
  'Open Pipeline v1',
  'Returns open pipeline value from the canonical deal contract for a bounded expected-close period.',
  $sql$
SELECT COALESCE(SUM(amount), 0)::numeric(18,2) AS metric_value
FROM reporting.deals
WHERE stage_category = 'open'
  AND expected_close_date >= $1::timestamptz
  AND expected_close_date < $2::timestamptz
$sql$,
  ARRAY['start_at','end_at'],
  'scalar',
  1,
  1,
  true
),
(
  'closed_won_deals_v1',
  'Closed Won Deals v1',
  'Returns the count of closed-won deals from the canonical deal contract for a bounded period.',
  $sql$
SELECT COUNT(*)::bigint AS metric_value
FROM reporting.deals
WHERE stage_category = 'won'
  AND closed_at >= $1::timestamptz
  AND closed_at < $2::timestamptz
$sql$,
  ARRAY['start_at','end_at'],
  'scalar',
  1,
  1,
  true
),
(
  'win_rate_v1',
  'Win Rate v1',
  'Returns closed-won deals divided by all closed deals for a bounded period.',
  $sql$
SELECT ROUND(
  100.0 * COUNT(*) FILTER (WHERE stage_category = 'won')
  / NULLIF(COUNT(*) FILTER (WHERE stage_category IN ('won','lost')), 0),
  2
) AS metric_value
FROM reporting.deals
WHERE stage_category IN ('won','lost')
  AND closed_at >= $1::timestamptz
  AND closed_at < $2::timestamptz
$sql$,
  ARRAY['start_at','end_at'],
  'scalar',
  1,
  1,
  true
)
ON CONFLICT (query_key) DO UPDATE SET
  query_name = EXCLUDED.query_name,
  description = EXCLUDED.description,
  sql_template = EXCLUDED.sql_template,
  allowed_parameters = EXCLUDED.allowed_parameters,
  result_type = EXCLUDED.result_type,
  maximum_rows = EXCLUDED.maximum_rows,
  version = EXCLUDED.version,
  active = EXCLUDED.active,
  updated_at = now();

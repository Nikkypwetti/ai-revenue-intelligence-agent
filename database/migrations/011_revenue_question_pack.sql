\set ON_ERROR_STOP on

-- Agent V2 reusable Revenue Question Pack.
-- Existing scalar execution remains intact for backwards compatibility.
-- The V2 report executor below adds broader governed metric packs and breakdowns.

ALTER TABLE governance.kpi_catalog
  ADD COLUMN IF NOT EXISTS metric_pack text NOT NULL DEFAULT 'core';

ALTER TABLE governance.kpi_catalog
  ADD COLUMN IF NOT EXISTS required_data_domains text[] NOT NULL DEFAULT ARRAY['deals']::text[];

ALTER TABLE governance.kpi_catalog
  DROP CONSTRAINT IF EXISTS kpi_catalog_calculation_type_check;
ALTER TABLE governance.kpi_catalog
  ADD CONSTRAINT kpi_catalog_calculation_type_check
  CHECK (
    calculation_type IS NULL
    OR calculation_type IN ('sum','count','ratio','average','derived')
  );

ALTER TABLE governance.connector_registry
  DROP CONSTRAINT IF EXISTS connector_registry_connector_type_check;
ALTER TABLE governance.connector_registry
  ADD CONSTRAINT connector_registry_connector_type_check
  CHECK (
    connector_type IN (
      'hubspot','salesforce','airtable','postgresql',
      'google_sheets','billing','rest_api'
    )
  );

ALTER TABLE governance.connector_registry
  DROP CONSTRAINT IF EXISTS connector_registry_object_type_check;
ALTER TABLE governance.connector_registry
  ADD CONSTRAINT connector_registry_object_type_check
  CHECK (object_type IN ('deal','funnel','activity','subscription','target','forecast'));

ALTER TABLE governance.connector_field_mapping
  DROP CONSTRAINT IF EXISTS connector_field_mapping_canonical_field_check;
ALTER TABLE governance.connector_field_mapping
  ADD CONSTRAINT connector_field_mapping_canonical_field_check
  CHECK (
    canonical_field IN (
      'deal_name','amount','currency_code','stage_name','stage_category',
      'sales_rep','lead_source','created_at','expected_close_date',
      'closed_at','source_updated_at','probability_percent','forecast_category',
      'account_key','segment','region','industry','campaign',
      'qualified_at','opportunity_at','proposal_sent_at','stage_entered_at',
      'last_activity_at','next_activity_at','first_response_at','sla_due_at',
      'lost_reason','annual_contract_value','monthly_recurring_revenue',
      'list_amount','discount_percent',
      'mql_at','sql_at','won_at','lost_at',
      'deal_source_record_id','activity_type','occurred_at','due_at','completed_at',
      'subscription_event_type','mrr_delta',
      'target_type','department_key','period_start','period_end','target_amount',
      'snapshot_at','forecast_amount','actual_amount'
    )
  );

ALTER TABLE governance.connector_value_mapping
  DROP CONSTRAINT IF EXISTS connector_value_mapping_canonical_field_check;
ALTER TABLE governance.connector_value_mapping
  DROP CONSTRAINT IF EXISTS connector_value_mapping_canonical_value_check;
ALTER TABLE governance.connector_value_mapping
  ADD CONSTRAINT connector_value_mapping_canonical_field_check
  CHECK (
    canonical_field IN (
      'stage_category','forecast_category','activity_type',
      'subscription_event_type','target_type'
    )
  );
ALTER TABLE governance.connector_value_mapping
  ADD CONSTRAINT connector_value_mapping_canonical_value_check
  CHECK (
    (canonical_field='stage_category'
      AND canonical_value IN ('open','won','lost'))
    OR
    (canonical_field='forecast_category'
      AND canonical_value IN ('pipeline','best_case','commit','closed','omitted'))
    OR
    (canonical_field='activity_type'
      AND canonical_value IN ('task','email','call','meeting','other'))
    OR
    (canonical_field='subscription_event_type'
      AND canonical_value IN ('start','expansion','contraction','churn','renewal'))
    OR
    (canonical_field='target_type'
      AND canonical_value IN ('revenue_quota','pipeline_target'))
  );

ALTER TABLE governance.dimension_catalog
  DROP CONSTRAINT IF EXISTS dimension_catalog_canonical_column_check;
ALTER TABLE governance.dimension_catalog
  ADD CONSTRAINT dimension_catalog_canonical_column_check
  CHECK (
    canonical_column IN (
      'currency_code','stage_name','stage_category','sales_rep','lead_source',
      'segment','region','industry','campaign','forecast_category'
    )
  );

ALTER TABLE governance.date_field_catalog
  DROP CONSTRAINT IF EXISTS date_field_catalog_canonical_column_check;
ALTER TABLE governance.date_field_catalog
  ADD CONSTRAINT date_field_catalog_canonical_column_check
  CHECK (
    canonical_column IN (
      'created_at','expected_close_date','closed_at','source_updated_at',
      'last_activity_at','stage_entered_at','occurred_at','due_at','snapshot_at'
    )
  );

ALTER TABLE governance.filter_catalog
  DROP CONSTRAINT IF EXISTS filter_catalog_check;
ALTER TABLE governance.filter_catalog
  DROP CONSTRAINT IF EXISTS filter_catalog_canonical_column_check;
ALTER TABLE governance.filter_catalog
  ADD CONSTRAINT filter_catalog_canonical_column_check
  CHECK (
    (filter_kind='date_range' AND canonical_column IS NULL)
    OR (
      filter_kind='field'
      AND canonical_column IN (
        'currency_code','stage_name','stage_category','sales_rep','lead_source',
        'segment','region','industry','campaign','forecast_category'
      )
    )
  );

ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS probability_percent numeric(5,2);
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS forecast_category text;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS account_key text;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS segment text;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS region text;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS industry text;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS campaign text;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS qualified_at timestamptz;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS opportunity_at timestamptz;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS proposal_sent_at timestamptz;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS stage_entered_at timestamptz;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS last_activity_at timestamptz;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS next_activity_at timestamptz;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS first_response_at timestamptz;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS sla_due_at timestamptz;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS lost_reason text;
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS annual_contract_value numeric(18,2);
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS monthly_recurring_revenue numeric(18,2);
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS list_amount numeric(18,2);
ALTER TABLE reporting.deals ADD COLUMN IF NOT EXISTS discount_percent numeric(6,2);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='deals_probability_percent_check'
      AND conrelid='reporting.deals'::regclass
  ) THEN
    ALTER TABLE reporting.deals
      ADD CONSTRAINT deals_probability_percent_check
      CHECK (probability_percent IS NULL OR probability_percent BETWEEN 0 AND 100);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='deals_forecast_category_check'
      AND conrelid='reporting.deals'::regclass
  ) THEN
    ALTER TABLE reporting.deals
      ADD CONSTRAINT deals_forecast_category_check
      CHECK (
        forecast_category IS NULL
        OR forecast_category IN ('pipeline','best_case','commit','closed','omitted')
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='deals_acv_check'
      AND conrelid='reporting.deals'::regclass
  ) THEN
    ALTER TABLE reporting.deals
      ADD CONSTRAINT deals_acv_check
      CHECK (annual_contract_value IS NULL OR annual_contract_value >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='deals_mrr_check'
      AND conrelid='reporting.deals'::regclass
  ) THEN
    ALTER TABLE reporting.deals
      ADD CONSTRAINT deals_mrr_check
      CHECK (monthly_recurring_revenue IS NULL OR monthly_recurring_revenue >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='deals_list_amount_check'
      AND conrelid='reporting.deals'::regclass
  ) THEN
    ALTER TABLE reporting.deals
      ADD CONSTRAINT deals_list_amount_check
      CHECK (list_amount IS NULL OR list_amount >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='deals_discount_percent_check'
      AND conrelid='reporting.deals'::regclass
  ) THEN
    ALTER TABLE reporting.deals
      ADD CONSTRAINT deals_discount_percent_check
      CHECK (discount_percent IS NULL OR discount_percent BETWEEN 0 AND 100);
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS governance.data_domain_status (
  domain_key text PRIMARY KEY,
  display_name text NOT NULL,
  description text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  data_ready boolean NOT NULL DEFAULT false,
  record_count bigint NOT NULL DEFAULT 0 CHECK (record_count >= 0),
  last_loaded_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (domain_key ~ '^[a-z][a-z0-9_]{1,63}$')
);

CREATE TABLE IF NOT EXISTS reporting.revenue_targets (
  target_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  connector_key text NOT NULL REFERENCES governance.connector_registry(connector_key),
  source_record_id text NOT NULL,
  target_type text NOT NULL CHECK (target_type IN ('revenue_quota','pipeline_target')),
  sales_rep text,
  department_key text,
  period_start date NOT NULL,
  period_end date NOT NULL,
  target_amount numeric(18,2) NOT NULL CHECK (target_amount >= 0),
  currency_code char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
  active boolean NOT NULL DEFAULT true,
  source_updated_at timestamptz,
  ingested_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (connector_key, source_record_id),
  CHECK (period_start <= period_end)
);

CREATE TABLE IF NOT EXISTS reporting.funnel_records (
  funnel_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  connector_key text NOT NULL REFERENCES governance.connector_registry(connector_key),
  source_record_id text NOT NULL,
  sales_rep text,
  lead_source text,
  campaign text,
  segment text,
  region text,
  industry text,
  created_at timestamptz NOT NULL,
  first_response_at timestamptz,
  mql_at timestamptz,
  sql_at timestamptz,
  opportunity_at timestamptz,
  won_at timestamptz,
  lost_at timestamptz,
  source_updated_at timestamptz,
  ingested_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (connector_key, source_record_id)
);

CREATE TABLE IF NOT EXISTS reporting.activities (
  activity_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  connector_key text NOT NULL REFERENCES governance.connector_registry(connector_key),
  source_record_id text NOT NULL,
  deal_source_record_id text,
  sales_rep text,
  activity_type text NOT NULL CHECK (
    activity_type IN ('task','email','call','meeting','other')
  ),
  occurred_at timestamptz,
  due_at timestamptz,
  completed_at timestamptz,
  source_updated_at timestamptz,
  ingested_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (connector_key, source_record_id)
);

CREATE TABLE IF NOT EXISTS reporting.subscription_events (
  subscription_event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  connector_key text NOT NULL REFERENCES governance.connector_registry(connector_key),
  source_record_id text NOT NULL,
  account_key text NOT NULL,
  sales_rep text,
  segment text,
  region text,
  industry text,
  event_type text NOT NULL CHECK (
    event_type IN ('start','expansion','contraction','churn','renewal')
  ),
  mrr_delta numeric(18,2) NOT NULL,
  currency_code char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
  occurred_at timestamptz NOT NULL,
  source_updated_at timestamptz,
  ingested_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (connector_key, source_record_id),
  CHECK (
    (event_type IN ('start','expansion') AND mrr_delta > 0)
    OR (event_type IN ('contraction','churn') AND mrr_delta < 0)
    OR (event_type='renewal' AND mrr_delta >= 0)
  )
);

CREATE TABLE IF NOT EXISTS reporting.forecast_snapshots (
  forecast_snapshot_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  connector_key text NOT NULL REFERENCES governance.connector_registry(connector_key),
  source_record_id text NOT NULL,
  snapshot_at timestamptz NOT NULL,
  period_start date NOT NULL,
  period_end date NOT NULL,
  sales_rep text,
  forecast_category text,
  forecast_amount numeric(18,2) NOT NULL CHECK (forecast_amount >= 0),
  actual_amount numeric(18,2) CHECK (actual_amount IS NULL OR actual_amount >= 0),
  currency_code char(3) NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
  source_updated_at timestamptz,
  ingested_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (connector_key, source_record_id),
  CHECK (period_start <= period_end),
  CHECK (
    forecast_category IS NULL
    OR forecast_category IN ('pipeline','best_case','commit','closed','omitted')
  )
);

CREATE INDEX IF NOT EXISTS deals_closed_at_idx ON reporting.deals(closed_at);
CREATE INDEX IF NOT EXISTS deals_expected_close_date_idx ON reporting.deals(expected_close_date);
CREATE INDEX IF NOT EXISTS deals_sales_rep_idx ON reporting.deals(sales_rep);
CREATE INDEX IF NOT EXISTS funnel_records_created_at_idx ON reporting.funnel_records(created_at);
CREATE INDEX IF NOT EXISTS activities_due_at_idx ON reporting.activities(due_at);
CREATE INDEX IF NOT EXISTS subscription_events_occurred_at_idx ON reporting.subscription_events(occurred_at);
CREATE INDEX IF NOT EXISTS revenue_targets_period_idx ON reporting.revenue_targets(period_start,period_end);
CREATE INDEX IF NOT EXISTS forecast_snapshots_period_idx ON reporting.forecast_snapshots(period_start,period_end);

REVOKE ALL ON governance.data_domain_status FROM PUBLIC;
REVOKE ALL ON reporting.revenue_targets FROM PUBLIC;
REVOKE ALL ON reporting.funnel_records FROM PUBLIC;
REVOKE ALL ON reporting.activities FROM PUBLIC;
REVOKE ALL ON reporting.subscription_events FROM PUBLIC;
REVOKE ALL ON reporting.forecast_snapshots FROM PUBLIC;

GRANT SELECT ON reporting.revenue_targets TO revint_reporting_ro;
GRANT SELECT ON reporting.funnel_records TO revint_reporting_ro;
GRANT SELECT ON reporting.activities TO revint_reporting_ro;
GRANT SELECT ON reporting.subscription_events TO revint_reporting_ro;
GRANT SELECT ON reporting.forecast_snapshots TO revint_reporting_ro;

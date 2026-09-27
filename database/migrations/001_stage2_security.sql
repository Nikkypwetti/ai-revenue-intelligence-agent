\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS governance;
CREATE SCHEMA IF NOT EXISTS reporting;
CREATE SCHEMA IF NOT EXISTS audit;

REVOKE ALL ON SCHEMA governance, reporting, audit FROM PUBLIC;

CREATE TABLE IF NOT EXISTS governance.business_config (
  config_key text PRIMARY KEY DEFAULT 'default',
  company_name text NOT NULL,
  timezone text NOT NULL DEFAULT 'Etc/UTC',
  currency_code char(3) NOT NULL,
  fiscal_year_start_month smallint NOT NULL CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
  stale_deal_days integer NOT NULL CHECK (stale_deal_days > 0),
  minimum_pipeline_coverage numeric(8,2) NOT NULL CHECK (minimum_pipeline_coverage > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS governance.kpi_catalog (
  kpi_key text NOT NULL,
  version integer NOT NULL CHECK (version > 0),
  display_name text NOT NULL,
  description text NOT NULL,
  unit text NOT NULL,
  query_key text NOT NULL,
  default_date_field text,
  allowed_dimensions text[] NOT NULL DEFAULT '{}',
  allowed_filters text[] NOT NULL DEFAULT '{}',
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (kpi_key, version)
);

CREATE TABLE IF NOT EXISTS governance.role_policy (
  role_key text PRIMARY KEY,
  allowed_kpis text[] NOT NULL DEFAULT '{}',
  allowed_dimensions text[] NOT NULL DEFAULT '{}',
  max_rows integer NOT NULL DEFAULT 500 CHECK (max_rows BETWEEN 1 AND 10000),
  can_view_all_teams boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit.agent_events (
  event_id text PRIMARY KEY,
  request_id text,
  correlation_id text,
  event_type text NOT NULL,
  stage text NOT NULL,
  actor text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'revint_reporting_ro') THEN
    CREATE ROLE revint_reporting_ro NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'revint_governance_ro') THEN
    CREATE ROLE revint_governance_ro NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'revint_audit_insert') THEN
    CREATE ROLE revint_audit_insert NOLOGIN;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA reporting TO revint_reporting_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO revint_reporting_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA reporting
  GRANT SELECT ON TABLES TO revint_reporting_ro;

GRANT USAGE ON SCHEMA governance TO revint_governance_ro;
GRANT SELECT ON governance.business_config, governance.kpi_catalog, governance.role_policy
  TO revint_governance_ro;

GRANT USAGE ON SCHEMA audit TO revint_audit_insert;
GRANT INSERT ON audit.agent_events TO revint_audit_insert;

SELECT format('CREATE ROLE %I LOGIN', :'reader_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'reader_user')
\gexec

SELECT format('ALTER ROLE %I PASSWORD %L', :'reader_user', :'reader_password')
\gexec

SELECT format('GRANT revint_reporting_ro, revint_governance_ro TO %I', :'reader_user')
\gexec

SELECT format('CREATE ROLE %I LOGIN', :'audit_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'audit_user')
\gexec

SELECT format('ALTER ROLE %I PASSWORD %L', :'audit_user', :'audit_password')
\gexec

SELECT format('GRANT revint_audit_insert TO %I', :'audit_user')
\gexec

REVOKE CREATE ON SCHEMA public FROM PUBLIC;

\set ON_ERROR_STOP on


INSERT INTO governance.data_domain_status(
  domain_key,display_name,description,active,data_ready,record_count,last_loaded_at
)
VALUES
  ('deals','Deals','Canonical opportunity/deal facts.',true,false,0,NULL),
  ('targets','Targets','Revenue quota and target facts.',true,false,0,NULL),
  ('funnel','Funnel Lifecycle','Lead/MQL/SQL/opportunity lifecycle facts.',true,false,0,NULL),
  ('activities','Activities','Task and follow-up SLA facts.',true,false,0,NULL),
  ('subscriptions','Subscriptions','Recurring revenue event facts.',true,false,0,NULL),
  ('forecasts','Forecast Snapshots','Historical forecast-versus-actual facts.',true,false,0,NULL)
ON CONFLICT(domain_key) DO UPDATE SET
  display_name=EXCLUDED.display_name,
  description=EXCLUDED.description,
  active=true,
  updated_at=now();

UPDATE governance.data_domain_status
SET data_ready=data_ready
      OR EXISTS(SELECT 1 FROM reporting.deals)
      OR EXISTS(
        SELECT 1 FROM governance.connector_registry
        WHERE object_type='deal' AND active
      ),
    record_count=(SELECT count(*) FROM reporting.deals),
    last_loaded_at=CASE
      WHEN EXISTS(SELECT 1 FROM reporting.deals)
        OR EXISTS(
          SELECT 1 FROM governance.connector_registry
          WHERE object_type='deal' AND active
        )
      THEN COALESCE(last_loaded_at,now())
      ELSE last_loaded_at
    END,
    updated_at=now()
WHERE domain_key='deals';

UPDATE governance.data_domain_status
SET data_ready=data_ready OR EXISTS(SELECT 1 FROM reporting.revenue_targets),
    record_count=(SELECT count(*) FROM reporting.revenue_targets),
    last_loaded_at=CASE WHEN EXISTS(SELECT 1 FROM reporting.revenue_targets)
      THEN COALESCE(last_loaded_at,now()) ELSE last_loaded_at END,
    updated_at=now()
WHERE domain_key='targets';

UPDATE governance.data_domain_status
SET data_ready=data_ready OR EXISTS(SELECT 1 FROM reporting.funnel_records),
    record_count=(SELECT count(*) FROM reporting.funnel_records),
    last_loaded_at=CASE WHEN EXISTS(SELECT 1 FROM reporting.funnel_records)
      THEN COALESCE(last_loaded_at,now()) ELSE last_loaded_at END,
    updated_at=now()
WHERE domain_key='funnel';

UPDATE governance.data_domain_status
SET data_ready=data_ready OR EXISTS(SELECT 1 FROM reporting.activities),
    record_count=(SELECT count(*) FROM reporting.activities),
    last_loaded_at=CASE WHEN EXISTS(SELECT 1 FROM reporting.activities)
      THEN COALESCE(last_loaded_at,now()) ELSE last_loaded_at END,
    updated_at=now()
WHERE domain_key='activities';

UPDATE governance.data_domain_status
SET data_ready=data_ready OR EXISTS(SELECT 1 FROM reporting.subscription_events),
    record_count=(SELECT count(*) FROM reporting.subscription_events),
    last_loaded_at=CASE WHEN EXISTS(SELECT 1 FROM reporting.subscription_events)
      THEN COALESCE(last_loaded_at,now()) ELSE last_loaded_at END,
    updated_at=now()
WHERE domain_key='subscriptions';

UPDATE governance.data_domain_status
SET data_ready=data_ready OR EXISTS(SELECT 1 FROM reporting.forecast_snapshots),
    record_count=(SELECT count(*) FROM reporting.forecast_snapshots),
    last_loaded_at=CASE WHEN EXISTS(SELECT 1 FROM reporting.forecast_snapshots)
      THEN COALESCE(last_loaded_at,now()) ELSE last_loaded_at END,
    updated_at=now()
WHERE domain_key='forecasts';


INSERT INTO governance.dimension_catalog(
  dimension_key,display_name,description,canonical_column,data_type,active
)
VALUES
  ('segment','Segment','Canonical customer/deal segment.','segment','category',true),
  ('region','Region','Canonical geographic or territory region.','region','category',true),
  ('industry','Industry','Canonical account/deal industry.','industry','category',true),
  ('campaign','Campaign','Canonical campaign or attribution label.','campaign','category',true),
  ('forecast_category','Forecast Category','Canonical forecast classification.','forecast_category','category',true)
ON CONFLICT(dimension_key) DO UPDATE SET
  display_name=EXCLUDED.display_name,
  description=EXCLUDED.description,
  canonical_column=EXCLUDED.canonical_column,
  data_type=EXCLUDED.data_type,
  active=EXCLUDED.active,
  updated_at=now();

INSERT INTO governance.date_field_catalog(
  date_field_key,display_name,description,canonical_column,active
)
VALUES
  ('occurred_date','Occurred Date','Canonical event occurrence timestamp.','occurred_at',true),
  ('due_date','Due Date','Canonical activity due timestamp.','due_at',true),
  ('stage_entered_date','Stage Entered Date','Canonical stage-entry timestamp.','stage_entered_at',true),
  ('snapshot_date','Snapshot Date','Canonical forecast snapshot timestamp.','snapshot_at',true)
ON CONFLICT(date_field_key) DO UPDATE SET
  display_name=EXCLUDED.display_name,
  description=EXCLUDED.description,
  canonical_column=EXCLUDED.canonical_column,
  active=EXCLUDED.active,
  updated_at=now();

INSERT INTO governance.filter_catalog(
  filter_key,display_name,description,filter_kind,
  canonical_column,data_type,allowed_operators,active
)
VALUES
  ('segment','Segment','Filter by canonical segment.','field','segment','category',ARRAY['eq','in'],true),
  ('region','Region','Filter by canonical region.','field','region','category',ARRAY['eq','in'],true),
  ('industry','Industry','Filter by canonical industry.','field','industry','category',ARRAY['eq','in'],true),
  ('campaign','Campaign','Filter by canonical campaign.','field','campaign','category',ARRAY['eq','in'],true),
  ('forecast_category','Forecast Category','Filter by canonical forecast category.','field','forecast_category','category',ARRAY['eq','in'],true)
ON CONFLICT(filter_key) DO UPDATE SET
  display_name=EXCLUDED.display_name,
  description=EXCLUDED.description,
  filter_kind=EXCLUDED.filter_kind,
  canonical_column=EXCLUDED.canonical_column,
  data_type=EXCLUDED.data_type,
  allowed_operators=EXCLUDED.allowed_operators,
  active=EXCLUDED.active,
  updated_at=now();


INSERT INTO governance.query_templates(
  query_key,query_name,description,sql_template,allowed_parameters,
  result_type,maximum_rows,version,active
)
VALUES
('open_deals_count_v1','Open Deals Count v1','Count of open deals expected to close in the requested period.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: open_deals_count */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('weighted_pipeline_v1','Weighted Pipeline v1','Open pipeline weighted by governed probability_percent.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: weighted_pipeline */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('pipeline_coverage_ratio_v1','Pipeline Coverage Ratio v1','Open pipeline divided by governed revenue quota for the period.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: pipeline_coverage_ratio */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('stale_open_deals_count_v1','Stale Open Deals v1','Open deals older than the configured stale-deal threshold.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: stale_open_deals_count */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('stale_pipeline_value_v1','Stale Pipeline Value v1','Value of open deals older than the configured stale-deal threshold.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: stale_pipeline_value */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('missing_close_date_deals_v1','Missing Close Date Deals v1','Open deals created in the period with no expected close date.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: missing_close_date_deals */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('average_deal_size_v1','Average Deal Size v1','Average value of closed-won deals.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: average_deal_size */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('closed_lost_deals_v1','Closed Lost Deals v1','Count of lost deals in the requested period.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: closed_lost_deals */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('loss_rate_v1','Loss Rate v1','Lost closed deals divided by all closed deals.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: loss_rate */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('average_acv_v1','Average ACV v1','Average annual contract value of won deals.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: average_acv */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('average_discount_percent_v1','Average Discount v1','Average discount percent on won deals.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: average_discount_percent */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('commit_forecast_v1','Commit Forecast v1','Open pipeline categorized as commit for the requested period.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: commit_forecast */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('best_case_forecast_v1','Best Case Forecast v1','Open pipeline categorized as best case for the requested period.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: best_case_forecast */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('forecast_accuracy_v1','Forecast Accuracy v1','Accuracy of stored forecast snapshots versus actual revenue.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: forecast_accuracy */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('average_sales_cycle_days_v1','Average Sales Cycle v1','Average days from deal creation to close.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: average_sales_cycle_days */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('average_stage_age_days_v1','Average Stage Age v1','Average days open deals have remained in their current stage.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: average_stage_age_days */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('pipeline_velocity_v1','Pipeline Velocity v1','Open opportunity count multiplied by average won deal size and win rate, divided by average won sales cycle days.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: pipeline_velocity */',ARRAY['start_at','end_at','dimensions','filters']::text[],'scalar',1,1,true),
('quota_attainment_v1','Quota Attainment v1','Closed-won revenue divided by governed revenue quota.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: quota_attainment */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('speed_to_lead_hours_v1','Speed to Lead v1','Average hours from lead creation to first response.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: speed_to_lead_hours */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('follow_up_sla_compliance_v1','Follow-up SLA Compliance v1','Percent of due activities completed on or before their due time.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: follow_up_sla_compliance */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('overdue_followups_v1','Overdue Follow-ups v1','Count of activities past due without on-time completion.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: overdue_followups */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('crm_data_quality_score_v1','CRM Data Quality Score v1','Completeness score across core governed deal fields.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: crm_data_quality_score */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('missing_owner_deals_v1','Missing Owner Deals v1','Deals created in the period without a canonical sales owner.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: missing_owner_deals */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('lead_to_mql_rate_v1','Lead to MQL Conversion v1','Percent of created leads that reached MQL.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: lead_to_mql_rate */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('mql_to_sql_rate_v1','MQL to SQL Conversion v1','Percent of MQLs that reached SQL.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: mql_to_sql_rate */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('sql_to_opportunity_rate_v1','SQL to Opportunity Conversion v1','Percent of SQLs that became opportunities.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: sql_to_opportunity_rate */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('opportunity_to_won_rate_v1','Opportunity to Won Conversion v1','Percent of opportunities that became won customers.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: opportunity_to_won_rate */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('current_mrr_v1','Current MRR v1','Net monthly recurring revenue as of the end of the requested period.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: current_mrr */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('current_arr_v1','Current ARR v1','Annualized current MRR as of the end of the requested period.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: current_arr */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('expansion_mrr_v1','Expansion MRR v1','MRR added by expansion events in the requested period.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: expansion_mrr */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('churned_mrr_v1','Churned MRR v1','Absolute MRR lost to churn events in the requested period.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: churned_mrr */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('net_revenue_retention_v1','Net Revenue Retention v1','Starting MRR plus expansion, contraction and churn divided by starting MRR.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: net_revenue_retention */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true),
('gross_revenue_retention_v1','Gross Revenue Retention v1','Starting MRR less contraction and churn divided by starting MRR.','SELECT NULL::numeric AS metric_value /* governed by execute_agent_report_request_v2: gross_revenue_retention */',ARRAY['start_at','end_at','dimensions','filters']::text[],'breakdown',100,1,true)
ON CONFLICT(query_key) DO UPDATE SET
  query_name=EXCLUDED.query_name,
  description=EXCLUDED.description,
  sql_template=EXCLUDED.sql_template,
  allowed_parameters=EXCLUDED.allowed_parameters,
  result_type=EXCLUDED.result_type,
  maximum_rows=EXCLUDED.maximum_rows,
  version=EXCLUDED.version,
  active=EXCLUDED.active,
  updated_at=now();


INSERT INTO governance.kpi_catalog(
  kpi_key,version,display_name,description,unit,query_key,default_date_field,
  allowed_dimensions,allowed_filters,active,calculation_type,formula_expression,
  metric_pack,required_data_domains
)
VALUES
('closed_won_revenue',1,'Closed Won Revenue','Closed-won revenue in the requested closed-date period.','currency','closed_won_revenue_v1','closed_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'sum','SUM(amount) for won deals','revenue',ARRAY['deals']::text[]),
('open_pipeline',1,'Open Pipeline','Open opportunity value in the requested expected-close period.','currency','open_pipeline_v1','expected_close_date',ARRAY['sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],ARRAY['date_range','sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],true,'sum','SUM(amount) for open deals','pipeline',ARRAY['deals']::text[]),
('closed_won_deals',1,'Closed Won Deals','Count of won deals in the requested closed-date period.','count','closed_won_deals_v1','closed_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'count','COUNT(won deals)','revenue',ARRAY['deals']::text[]),
('win_rate',1,'Win Rate','Won closed deals divided by all closed deals.','percent','win_rate_v1','closed_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'ratio','100 * won / (won + lost)','revenue',ARRAY['deals']::text[]),
('open_deals_count',1,'Open Deals Count','Count of open deals expected to close in the requested period.','count','open_deals_count_v1','expected_close_date',ARRAY['sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],ARRAY['date_range','sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],true,'count','COUNT(open deals)','pipeline',ARRAY['deals']::text[]),
('weighted_pipeline',1,'Weighted Pipeline','Open pipeline weighted by governed probability_percent.','currency','weighted_pipeline_v1','expected_close_date',ARRAY['sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],ARRAY['date_range','sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],true,'sum','SUM(amount * probability_percent / 100)','pipeline',ARRAY['deals']::text[]),
('pipeline_coverage_ratio',1,'Pipeline Coverage Ratio','Open pipeline divided by governed revenue quota for the period.','ratio','pipeline_coverage_ratio_v1','expected_close_date',ARRAY['sales_rep']::text[],ARRAY['date_range','sales_rep']::text[],true,'ratio','open pipeline / revenue quota','pipeline',ARRAY['deals','targets']::text[]),
('stale_open_deals_count',1,'Stale Open Deals','Open deals older than the configured stale-deal threshold.','count','stale_open_deals_count_v1','expected_close_date',ARRAY['sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],ARRAY['date_range','sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],true,'count','COUNT(open deals with stale activity/source update)','pipeline',ARRAY['deals']::text[]),
('stale_pipeline_value',1,'Stale Pipeline Value','Value of open deals older than the configured stale-deal threshold.','currency','stale_pipeline_value_v1','expected_close_date',ARRAY['sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],ARRAY['date_range','sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],true,'sum','SUM(amount) for stale open deals','pipeline',ARRAY['deals']::text[]),
('missing_close_date_deals',1,'Missing Close Date Deals','Open deals created in the period with no expected close date.','count','missing_close_date_deals_v1','created_date',ARRAY['lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','lead_source','segment','region','industry','campaign']::text[],true,'count','COUNT(open deals missing expected_close_date)','data_quality',ARRAY['deals']::text[]),
('average_deal_size',1,'Average Deal Size','Average value of closed-won deals.','currency','average_deal_size_v1','closed_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'average','AVG(amount) for won deals','revenue',ARRAY['deals']::text[]),
('closed_lost_deals',1,'Closed Lost Deals','Count of lost deals in the requested period.','count','closed_lost_deals_v1','closed_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'count','COUNT(lost deals)','revenue',ARRAY['deals']::text[]),
('loss_rate',1,'Loss Rate','Lost closed deals divided by all closed deals.','percent','loss_rate_v1','closed_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'ratio','100 * lost / (won + lost)','revenue',ARRAY['deals']::text[]),
('average_acv',1,'Average ACV','Average annual contract value of won deals.','currency','average_acv_v1','closed_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'average','AVG(annual_contract_value) for won deals','revenue',ARRAY['deals']::text[]),
('average_discount_percent',1,'Average Discount','Average discount percent on won deals.','percent','average_discount_percent_v1','closed_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'average','AVG(discount_percent) for won deals','revenue',ARRAY['deals']::text[]),
('commit_forecast',1,'Commit Forecast','Open pipeline categorized as commit for the requested period.','currency','commit_forecast_v1','expected_close_date',ARRAY['sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],ARRAY['date_range','sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],true,'sum','SUM(amount) where forecast_category = commit','forecast',ARRAY['deals']::text[]),
('best_case_forecast',1,'Best Case Forecast','Open pipeline categorized as best case for the requested period.','currency','best_case_forecast_v1','expected_close_date',ARRAY['sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],ARRAY['date_range','sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],true,'sum','SUM(amount) where forecast_category = best_case','forecast',ARRAY['deals']::text[]),
('forecast_accuracy',1,'Forecast Accuracy','Accuracy of stored forecast snapshots versus actual revenue.','percent','forecast_accuracy_v1','snapshot_date',ARRAY['sales_rep']::text[],ARRAY['date_range','sales_rep']::text[],true,'derived','100 * (1 - abs(forecast - actual) / actual), floored at zero','forecast',ARRAY['forecasts']::text[]),
('average_sales_cycle_days',1,'Average Sales Cycle','Average days from deal creation to close.','days','average_sales_cycle_days_v1','closed_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'average','AVG(closed_at - created_at) in days','velocity',ARRAY['deals']::text[]),
('average_stage_age_days',1,'Average Stage Age','Average days open deals have remained in their current stage.','days','average_stage_age_days_v1','expected_close_date',ARRAY['sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],ARRAY['date_range','sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],true,'average','AVG(as_of - stage_entered_at) for open deals','velocity',ARRAY['deals']::text[]),
('pipeline_velocity',1,'Pipeline Velocity','Open opportunity count multiplied by average won deal size and win rate, divided by average won sales cycle days.','currency_per_day','pipeline_velocity_v1','expected_close_date',ARRAY[]::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'derived','open_count * avg_won_amount * win_rate / avg_won_cycle_days','velocity',ARRAY['deals']::text[]),
('quota_attainment',1,'Quota Attainment','Closed-won revenue divided by governed revenue quota.','percent','quota_attainment_v1','closed_date',ARRAY['sales_rep']::text[],ARRAY['date_range','sales_rep']::text[],true,'ratio','100 * won revenue / revenue quota','performance',ARRAY['deals','targets']::text[]),
('speed_to_lead_hours',1,'Speed to Lead','Average hours from lead creation to first response.','hours','speed_to_lead_hours_v1','created_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'average','AVG(first_response_at - created_at) in hours','activity',ARRAY['funnel']::text[]),
('follow_up_sla_compliance',1,'Follow-up SLA Compliance','Percent of due activities completed on or before their due time.','percent','follow_up_sla_compliance_v1','due_date',ARRAY['sales_rep']::text[],ARRAY['date_range','sales_rep']::text[],true,'ratio','100 * on-time completed activities / due activities','activity',ARRAY['activities']::text[]),
('overdue_followups',1,'Overdue Follow-ups','Count of activities past due without on-time completion.','count','overdue_followups_v1','due_date',ARRAY['sales_rep']::text[],ARRAY['date_range','sales_rep']::text[],true,'count','COUNT(overdue activities)','activity',ARRAY['activities']::text[]),
('crm_data_quality_score',1,'CRM Data Quality Score','Completeness score across core governed deal fields.','percent','crm_data_quality_score_v1','created_date',ARRAY['sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],ARRAY['date_range','sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],true,'derived','Completeness across deal name, owner, source, stage, amount, and close-date validity','data_quality',ARRAY['deals']::text[]),
('missing_owner_deals',1,'Missing Owner Deals','Deals created in the period without a canonical sales owner.','count','missing_owner_deals_v1','created_date',ARRAY['lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','lead_source','segment','region','industry','campaign']::text[],true,'count','COUNT(deals with missing sales_rep)','data_quality',ARRAY['deals']::text[]),
('lead_to_mql_rate',1,'Lead to MQL Conversion','Percent of created leads that reached MQL.','percent','lead_to_mql_rate_v1','created_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'ratio','100 * MQL / created leads','funnel',ARRAY['funnel']::text[]),
('mql_to_sql_rate',1,'MQL to SQL Conversion','Percent of MQLs that reached SQL.','percent','mql_to_sql_rate_v1','created_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'ratio','100 * SQL / MQL','funnel',ARRAY['funnel']::text[]),
('sql_to_opportunity_rate',1,'SQL to Opportunity Conversion','Percent of SQLs that became opportunities.','percent','sql_to_opportunity_rate_v1','created_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'ratio','100 * opportunities / SQL','funnel',ARRAY['funnel']::text[]),
('opportunity_to_won_rate',1,'Opportunity to Won Conversion','Percent of opportunities that became won customers.','percent','opportunity_to_won_rate_v1','created_date',ARRAY['sales_rep','lead_source','segment','region','industry','campaign']::text[],ARRAY['date_range','sales_rep','lead_source','segment','region','industry','campaign']::text[],true,'ratio','100 * won / opportunities','funnel',ARRAY['funnel']::text[]),
('current_mrr',1,'Current MRR','Net monthly recurring revenue as of the end of the requested period.','currency','current_mrr_v1','occurred_date',ARRAY['sales_rep','segment','region','industry']::text[],ARRAY['date_range','sales_rep','segment','region','industry']::text[],true,'sum','SUM(subscription mrr_delta) before period end','retention',ARRAY['subscriptions']::text[]),
('current_arr',1,'Current ARR','Annualized current MRR as of the end of the requested period.','currency','current_arr_v1','occurred_date',ARRAY['sales_rep','segment','region','industry']::text[],ARRAY['date_range','sales_rep','segment','region','industry']::text[],true,'derived','12 * current MRR','retention',ARRAY['subscriptions']::text[]),
('expansion_mrr',1,'Expansion MRR','MRR added by expansion events in the requested period.','currency','expansion_mrr_v1','occurred_date',ARRAY['sales_rep','segment','region','industry']::text[],ARRAY['date_range','sales_rep','segment','region','industry']::text[],true,'sum','SUM(expansion mrr_delta)','retention',ARRAY['subscriptions']::text[]),
('churned_mrr',1,'Churned MRR','Absolute MRR lost to churn events in the requested period.','currency','churned_mrr_v1','occurred_date',ARRAY['sales_rep','segment','region','industry']::text[],ARRAY['date_range','sales_rep','segment','region','industry']::text[],true,'sum','ABS(SUM(churn mrr_delta))','retention',ARRAY['subscriptions']::text[]),
('net_revenue_retention',1,'Net Revenue Retention','Starting MRR plus expansion, contraction and churn divided by starting MRR.','percent','net_revenue_retention_v1','occurred_date',ARRAY['sales_rep','segment','region','industry']::text[],ARRAY['date_range','sales_rep','segment','region','industry']::text[],true,'ratio','100 * (starting MRR + net change) / starting MRR','retention',ARRAY['subscriptions']::text[]),
('gross_revenue_retention',1,'Gross Revenue Retention','Starting MRR less contraction and churn divided by starting MRR.','percent','gross_revenue_retention_v1','occurred_date',ARRAY['sales_rep','segment','region','industry']::text[],ARRAY['date_range','sales_rep','segment','region','industry']::text[],true,'ratio','100 * (starting MRR - contraction - churn) / starting MRR','retention',ARRAY['subscriptions']::text[])
ON CONFLICT(kpi_key,version) DO UPDATE SET
  display_name=EXCLUDED.display_name,
  description=EXCLUDED.description,
  unit=EXCLUDED.unit,
  query_key=EXCLUDED.query_key,
  default_date_field=EXCLUDED.default_date_field,
  allowed_dimensions=EXCLUDED.allowed_dimensions,
  allowed_filters=EXCLUDED.allowed_filters,
  active=EXCLUDED.active,
  calculation_type=EXCLUDED.calculation_type,
  formula_expression=EXCLUDED.formula_expression,
  metric_pack=EXCLUDED.metric_pack,
  required_data_domains=EXCLUDED.required_data_domains;


DELETE FROM governance.kpi_dimension_policy p
USING governance.kpi_catalog k
WHERE p.kpi_key=k.kpi_key
  AND p.kpi_version=k.version
  AND NOT (p.dimension_key=ANY(k.allowed_dimensions));

INSERT INTO governance.kpi_dimension_policy(
  kpi_key,kpi_version,dimension_key
)
SELECT k.kpi_key,k.version,d.dimension_key
FROM governance.kpi_catalog k
CROSS JOIN LATERAL unnest(k.allowed_dimensions) requested(dimension_key)
JOIN governance.dimension_catalog d
  ON d.dimension_key=requested.dimension_key
 AND d.active
WHERE k.active
ON CONFLICT DO NOTHING;

DELETE FROM governance.kpi_filter_policy p
USING governance.kpi_catalog k
WHERE p.kpi_key=k.kpi_key
  AND p.kpi_version=k.version
  AND NOT (p.filter_key=ANY(k.allowed_filters));

INSERT INTO governance.kpi_filter_policy(
  kpi_key,kpi_version,filter_key
)
SELECT k.kpi_key,k.version,f.filter_key
FROM governance.kpi_catalog k
CROSS JOIN LATERAL unnest(k.allowed_filters) requested(filter_key)
JOIN governance.filter_catalog f
  ON f.filter_key=requested.filter_key
 AND f.active
WHERE k.active
ON CONFLICT DO NOTHING;


UPDATE governance.role_policy
SET allowed_kpis=ARRAY['closed_won_revenue','open_pipeline','closed_won_deals','win_rate','open_deals_count','weighted_pipeline','pipeline_coverage_ratio','stale_open_deals_count','stale_pipeline_value','missing_close_date_deals','average_deal_size','closed_lost_deals','loss_rate','average_acv','average_discount_percent','commit_forecast','best_case_forecast','forecast_accuracy','average_sales_cycle_days','average_stage_age_days','pipeline_velocity','quota_attainment','speed_to_lead_hours','follow_up_sla_compliance','overdue_followups','crm_data_quality_score','missing_owner_deals','lead_to_mql_rate','mql_to_sql_rate','sql_to_opportunity_rate','opportunity_to_won_rate','current_mrr','current_arr','expansion_mrr','churned_mrr','net_revenue_retention','gross_revenue_retention']::text[],
    allowed_dimensions=ARRAY['sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],
    allowed_filters=ARRAY['date_range','sales_rep','deal_stage','lead_source','segment','region','industry','campaign','forecast_category']::text[],
    updated_at=now()
WHERE role_key IN ('revenue_admin','revenue_manager','sales_rep');

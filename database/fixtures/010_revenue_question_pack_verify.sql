\set ON_ERROR_STOP on

INSERT INTO governance.principal_registry(
  principal_key,display_name,identity_provider,external_subject,canonical_sales_rep,active
)
VALUES ('verify-qpack-admin','Verify QPack Admin','test','verify-qpack-admin',NULL,true)
ON CONFLICT(principal_key) DO UPDATE SET active=true;

INSERT INTO governance.principal_registry(
  principal_key,display_name,identity_provider,external_subject,canonical_sales_rep,active
)
VALUES ('verify-qpack-rep','Verify QPack Rep','test','verify-qpack-rep','QP Alpha',true)
ON CONFLICT(principal_key) DO UPDATE SET
  canonical_sales_rep='QP Alpha',active=true;

INSERT INTO governance.role_assignment(principal_key,role_key,active)
VALUES
  ('verify-qpack-admin','revenue_admin',true),
  ('verify-qpack-rep','sales_rep',true)
ON CONFLICT(principal_key,role_key) DO UPDATE SET active=true;

INSERT INTO governance.connector_registry(
  connector_key,connector_type,display_name,object_type,contract_version,active
)
VALUES
 ('verify_qp_deal','rest_api','Verify Deal','deal',1,true),
 ('verify_qp_funnel','rest_api','Verify Funnel','funnel',1,true),
 ('verify_qp_activity','rest_api','Verify Activity','activity',1,true),
 ('verify_qp_subscription','billing','Verify Subscription','subscription',1,true),
 ('verify_qp_target','rest_api','Verify Target','target',1,true),
 ('verify_qp_forecast','rest_api','Verify Forecast','forecast',1,true)
ON CONFLICT(connector_key) DO UPDATE SET active=true,object_type=EXCLUDED.object_type;

INSERT INTO governance.connector_field_mapping(
  connector_key,canonical_field,source_field,transform_key,required,default_value,active
)
VALUES
 ('verify_qp_deal','deal_name','deal_name','text',false,NULL,true),
 ('verify_qp_deal','amount','amount','numeric',true,NULL,true),
 ('verify_qp_deal','currency_code','currency_code','uppercase',true,NULL,true),
 ('verify_qp_deal','stage_name','stage_name','text',true,NULL,true),
 ('verify_qp_deal','stage_category','stage_category','text',true,NULL,true),
 ('verify_qp_deal','sales_rep','sales_rep','text',false,NULL,true),
 ('verify_qp_deal','lead_source','lead_source','text',false,NULL,true),
 ('verify_qp_deal','created_at','created_at','timestamp',false,NULL,true),
 ('verify_qp_deal','expected_close_date','expected_close_date','timestamp',false,NULL,true),
 ('verify_qp_deal','closed_at','closed_at','timestamp',false,NULL,true),
 ('verify_qp_deal','source_updated_at','source_updated_at','timestamp',false,NULL,true),
 ('verify_qp_deal','probability_percent','probability_percent','numeric',false,NULL,true),
 ('verify_qp_deal','forecast_category','forecast_category','text',false,NULL,true),
 ('verify_qp_deal','segment','segment','text',false,NULL,true),
 ('verify_qp_deal','region','region','text',false,NULL,true),
 ('verify_qp_deal','industry','industry','text',false,NULL,true),
 ('verify_qp_deal','campaign','campaign','text',false,NULL,true),
 ('verify_qp_deal','stage_entered_at','stage_entered_at','timestamp',false,NULL,true),
 ('verify_qp_deal','last_activity_at','last_activity_at','timestamp',false,NULL,true),
 ('verify_qp_deal','lost_reason','lost_reason','text',false,NULL,true),
 ('verify_qp_deal','annual_contract_value','annual_contract_value','numeric',false,NULL,true),
 ('verify_qp_deal','discount_percent','discount_percent','numeric',false,NULL,true),

 ('verify_qp_funnel','sales_rep','sales_rep','text',false,NULL,true),
 ('verify_qp_funnel','lead_source','lead_source','text',false,NULL,true),
 ('verify_qp_funnel','campaign','campaign','text',false,NULL,true),
 ('verify_qp_funnel','segment','segment','text',false,NULL,true),
 ('verify_qp_funnel','region','region','text',false,NULL,true),
 ('verify_qp_funnel','industry','industry','text',false,NULL,true),
 ('verify_qp_funnel','created_at','created_at','timestamp',true,NULL,true),
 ('verify_qp_funnel','first_response_at','first_response_at','timestamp',false,NULL,true),
 ('verify_qp_funnel','mql_at','mql_at','timestamp',false,NULL,true),
 ('verify_qp_funnel','sql_at','sql_at','timestamp',false,NULL,true),
 ('verify_qp_funnel','opportunity_at','opportunity_at','timestamp',false,NULL,true),
 ('verify_qp_funnel','won_at','won_at','timestamp',false,NULL,true),
 ('verify_qp_funnel','lost_at','lost_at','timestamp',false,NULL,true),
 ('verify_qp_funnel','source_updated_at','source_updated_at','timestamp',false,NULL,true),

 ('verify_qp_activity','sales_rep','sales_rep','text',false,NULL,true),
 ('verify_qp_activity','activity_type','activity_type','text',true,NULL,true),
 ('verify_qp_activity','due_at','due_at','timestamp',false,NULL,true),
 ('verify_qp_activity','occurred_at','occurred_at','timestamp',false,NULL,true),
 ('verify_qp_activity','completed_at','completed_at','timestamp',false,NULL,true),
 ('verify_qp_activity','source_updated_at','source_updated_at','timestamp',false,NULL,true),

 ('verify_qp_subscription','account_key','account_key','text',true,NULL,true),
 ('verify_qp_subscription','sales_rep','sales_rep','text',false,NULL,true),
 ('verify_qp_subscription','segment','segment','text',false,NULL,true),
 ('verify_qp_subscription','region','region','text',false,NULL,true),
 ('verify_qp_subscription','industry','industry','text',false,NULL,true),
 ('verify_qp_subscription','subscription_event_type','event_type','text',true,NULL,true),
 ('verify_qp_subscription','mrr_delta','mrr_delta','numeric',true,NULL,true),
 ('verify_qp_subscription','currency_code','currency_code','uppercase',true,NULL,true),
 ('verify_qp_subscription','occurred_at','occurred_at','timestamp',true,NULL,true),
 ('verify_qp_subscription','source_updated_at','source_updated_at','timestamp',false,NULL,true),

 ('verify_qp_target','target_type','target_type','text',true,NULL,true),
 ('verify_qp_target','sales_rep','sales_rep','text',false,NULL,true),
 ('verify_qp_target','department_key','department_key','text',false,NULL,true),
 ('verify_qp_target','period_start','period_start','timestamp',true,NULL,true),
 ('verify_qp_target','period_end','period_end','timestamp',true,NULL,true),
 ('verify_qp_target','target_amount','target_amount','numeric',true,NULL,true),
 ('verify_qp_target','currency_code','currency_code','uppercase',true,NULL,true),
 ('verify_qp_target','source_updated_at','source_updated_at','timestamp',false,NULL,true),

 ('verify_qp_forecast','snapshot_at','snapshot_at','timestamp',true,NULL,true),
 ('verify_qp_forecast','period_start','period_start','timestamp',true,NULL,true),
 ('verify_qp_forecast','period_end','period_end','timestamp',true,NULL,true),
 ('verify_qp_forecast','sales_rep','sales_rep','text',false,NULL,true),
 ('verify_qp_forecast','forecast_category','forecast_category','text',false,NULL,true),
 ('verify_qp_forecast','forecast_amount','forecast_amount','numeric',true,NULL,true),
 ('verify_qp_forecast','actual_amount','actual_amount','numeric',false,NULL,true),
 ('verify_qp_forecast','currency_code','currency_code','uppercase',true,NULL,true),
 ('verify_qp_forecast','source_updated_at','source_updated_at','timestamp',false,NULL,true)
ON CONFLICT(connector_key,canonical_field) DO UPDATE SET
  source_field=EXCLUDED.source_field,
  transform_key=EXCLUDED.transform_key,
  required=EXCLUDED.required,
  default_value=EXCLUDED.default_value,
  active=true;

-- Deals
SELECT ingestion.ingest_revenue_domain_record_v2(
  'verify_qp_deal','d-open-a',
  jsonb_build_object(
    'deal_name','Open A','amount',1000,
    'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),
    'stage_name','Proposal','stage_category','open','sales_rep','QP Alpha',
    'lead_source','QPVerify','created_at','2026-08-01T12:00:00Z',
    'expected_close_date','2026-09-20T12:00:00Z','source_updated_at','2026-09-12T12:00:00Z',
    'probability_percent',50,'forecast_category','commit','segment','SMB',
    'region','West','industry','Technology','campaign','QPCampA',
    'stage_entered_at','2026-09-05T12:00:00Z','last_activity_at','2026-09-12T12:00:00Z'
  )
);
SELECT ingestion.ingest_revenue_domain_record_v2(
  'verify_qp_deal','d-open-b',
  jsonb_build_object(
    'deal_name','Open B','amount',2000,
    'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),
    'stage_name','Negotiation','stage_category','open','sales_rep','QP Beta',
    'lead_source','QPVerify','created_at','2026-08-05T12:00:00Z',
    'expected_close_date','2026-09-25T12:00:00Z','source_updated_at','2026-08-20T12:00:00Z',
    'probability_percent',25,'forecast_category','best_case','segment','Enterprise',
    'region','East','industry','Technology','campaign','QPCampB',
    'stage_entered_at','2026-08-15T12:00:00Z','last_activity_at','2026-08-20T12:00:00Z'
  )
);
SELECT ingestion.ingest_revenue_domain_record_v2(
  'verify_qp_deal','d-won-a',
  jsonb_build_object(
    'deal_name','Won A','amount',1500,
    'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),
    'stage_name','Closed Won','stage_category','won','sales_rep','QP Alpha',
    'lead_source','QPVerify','created_at','2026-08-01T12:00:00Z',
    'closed_at','2026-09-10T12:00:00Z','source_updated_at','2026-09-10T13:00:00Z',
    'probability_percent',100,'forecast_category','closed','segment','SMB',
    'region','West','industry','Technology','campaign','QPCampA',
    'annual_contract_value',1800,'discount_percent',10
  )
);
SELECT ingestion.ingest_revenue_domain_record_v2(
  'verify_qp_deal','d-won-b',
  jsonb_build_object(
    'deal_name','Won B','amount',2500,
    'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),
    'stage_name','Closed Won','stage_category','won','sales_rep','QP Beta',
    'lead_source','QPVerify','created_at','2026-07-15T12:00:00Z',
    'closed_at','2026-09-12T12:00:00Z','source_updated_at','2026-09-12T13:00:00Z',
    'probability_percent',100,'forecast_category','closed','segment','Enterprise',
    'region','East','industry','Technology','campaign','QPCampB',
    'annual_contract_value',3000,'discount_percent',20
  )
);
SELECT ingestion.ingest_revenue_domain_record_v2(
  'verify_qp_deal','d-lost-a',
  jsonb_build_object(
    'deal_name','Lost A','amount',1200,
    'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),
    'stage_name','Closed Lost','stage_category','lost','sales_rep','QP Alpha',
    'lead_source','QPVerify','created_at','2026-08-10T12:00:00Z',
    'closed_at','2026-09-13T12:00:00Z','source_updated_at','2026-09-13T13:00:00Z',
    'probability_percent',0,'forecast_category','omitted','segment','SMB',
    'region','West','industry','Technology','campaign','QPCampA',
    'lost_reason','Price'
  )
);
SELECT ingestion.ingest_revenue_domain_record_v2(
  'verify_qp_deal','d-quality-missing',
  jsonb_build_object(
    'deal_name','Quality Missing','amount',500,
    'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),
    'stage_name','Discovery','stage_category','open',
    'lead_source','QPQuality','created_at','2026-09-05T12:00:00Z',
    'source_updated_at','2026-09-06T12:00:00Z'
  )
);
SELECT ingestion.ingest_revenue_domain_record_v2(
  'verify_qp_deal','d-incomplete-probability',
  jsonb_build_object(
    'deal_name','Incomplete Probability','amount',700,
    'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),
    'stage_name','Discovery','stage_category','open','sales_rep','QP Gamma',
    'lead_source','QPIncomplete','created_at','2026-09-05T12:00:00Z',
    'expected_close_date','2026-09-22T12:00:00Z',
    'source_updated_at','2026-09-06T12:00:00Z'
  )
);

-- Funnel
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_funnel','f1',
  '{"sales_rep":"QP Alpha","lead_source":"QPVerify","campaign":"QPCampA","segment":"SMB","region":"West","industry":"Technology","created_at":"2026-09-02T10:00:00Z","first_response_at":"2026-09-02T11:00:00Z","mql_at":"2026-09-03T10:00:00Z","sql_at":"2026-09-04T10:00:00Z","opportunity_at":"2026-09-05T10:00:00Z","won_at":"2026-09-10T10:00:00Z"}'::jsonb);
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_funnel','f2',
  '{"sales_rep":"QP Alpha","lead_source":"QPVerify","campaign":"QPCampA","segment":"SMB","region":"West","industry":"Technology","created_at":"2026-09-03T10:00:00Z","first_response_at":"2026-09-03T12:00:00Z","mql_at":"2026-09-04T10:00:00Z","sql_at":"2026-09-05T10:00:00Z","opportunity_at":"2026-09-06T10:00:00Z","lost_at":"2026-09-12T10:00:00Z"}'::jsonb);
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_funnel','f3',
  '{"sales_rep":"QP Beta","lead_source":"QPVerify","campaign":"QPCampB","segment":"Enterprise","region":"East","industry":"Technology","created_at":"2026-09-04T10:00:00Z","first_response_at":"2026-09-04T14:00:00Z","mql_at":"2026-09-05T10:00:00Z"}'::jsonb);
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_funnel','f4',
  '{"sales_rep":"QP Beta","lead_source":"QPVerify","campaign":"QPCampB","segment":"Enterprise","region":"East","industry":"Technology","created_at":"2026-09-05T10:00:00Z","first_response_at":"2026-09-05T18:00:00Z"}'::jsonb);

-- Activities
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_activity','a1',
  '{"sales_rep":"QP Alpha","activity_type":"task","occurred_at":"2026-09-08T09:00:00Z","due_at":"2026-09-10T17:00:00Z","completed_at":"2026-09-09T17:00:00Z"}'::jsonb);
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_activity','a2',
  '{"sales_rep":"QP Alpha","activity_type":"task","occurred_at":"2026-09-09T09:00:00Z","due_at":"2026-09-11T17:00:00Z","completed_at":"2026-09-12T17:00:00Z"}'::jsonb);
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_activity','a3',
  '{"sales_rep":"QP Beta","activity_type":"task","occurred_at":"2026-09-10T09:00:00Z","due_at":"2026-09-12T17:00:00Z"}'::jsonb);

-- Targets
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_target','t-alpha',
  jsonb_build_object('target_type','revenue_quota','sales_rep','QP Alpha','period_start','2026-09-01T00:00:00Z','period_end','2026-09-30T00:00:00Z','target_amount',5000,'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1)));
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_target','t-beta',
  jsonb_build_object('target_type','revenue_quota','sales_rep','QP Beta','period_start','2026-09-01T00:00:00Z','period_end','2026-09-30T00:00:00Z','target_amount',5000,'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1)));

-- Subscription events
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_subscription','s1',
  jsonb_build_object('account_key','QP-A1','sales_rep','QP Alpha','segment','SMB','region','West','industry','Technology','event_type','start','mrr_delta',1000,'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),'occurred_at','2026-01-01T12:00:00Z'));
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_subscription','s2',
  jsonb_build_object('account_key','QP-A2','sales_rep','QP Beta','segment','Enterprise','region','East','industry','Technology','event_type','start','mrr_delta',1000,'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),'occurred_at','2026-02-01T12:00:00Z'));
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_subscription','s3',
  jsonb_build_object('account_key','QP-A1','sales_rep','QP Alpha','segment','SMB','region','West','industry','Technology','event_type','expansion','mrr_delta',500,'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),'occurred_at','2026-09-05T12:00:00Z'));
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_subscription','s4',
  jsonb_build_object('account_key','QP-A2','sales_rep','QP Beta','segment','Enterprise','region','East','industry','Technology','event_type','contraction','mrr_delta',-200,'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),'occurred_at','2026-09-10T12:00:00Z'));
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_subscription','s5',
  jsonb_build_object('account_key','QP-A2','sales_rep','QP Beta','segment','Enterprise','region','East','industry','Technology','event_type','churn','mrr_delta',-300,'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1),'occurred_at','2026-09-15T12:00:00Z'));

-- Forecast
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_forecast','fc1',
  jsonb_build_object('snapshot_at','2026-09-01T09:00:00Z','period_start','2026-09-01T00:00:00Z','period_end','2026-09-30T00:00:00Z','sales_rep','QP Alpha','forecast_category','commit','forecast_amount',2500,'actual_amount',1500,'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1)));
SELECT ingestion.ingest_revenue_domain_record_v2('verify_qp_forecast','fc2',
  jsonb_build_object('snapshot_at','2026-09-01T09:00:00Z','period_start','2026-09-01T00:00:00Z','period_end','2026-09-30T00:00:00Z','sales_rep','QP Beta','forecast_category','best_case','forecast_amount',2500,'actual_amount',2500,'currency_code',(SELECT trim(currency_code::text) FROM governance.business_config LIMIT 1)));

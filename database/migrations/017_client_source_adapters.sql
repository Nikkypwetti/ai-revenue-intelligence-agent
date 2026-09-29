\set ON_ERROR_STOP on

ALTER TABLE governance.connector_registry
  DROP CONSTRAINT IF EXISTS connector_registry_connector_type_check;
ALTER TABLE governance.connector_registry
  ADD CONSTRAINT connector_registry_connector_type_check
  CHECK (connector_type IN ('hubspot','salesforce','airtable','postgresql','google_sheets','billing','rest_api'));

CREATE TABLE IF NOT EXISTS governance.connector_runtime_config (
  connector_key text PRIMARY KEY REFERENCES governance.connector_registry(connector_key) ON DELETE CASCADE,
  provider_available boolean NOT NULL DEFAULT false,
  credential_validated boolean NOT NULL DEFAULT false,
  read_enabled boolean NOT NULL DEFAULT false,
  write_enabled boolean NOT NULL DEFAULT false,
  blocked_reason text,
  provider_config jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON governance.connector_runtime_config FROM PUBLIC;

INSERT INTO governance.connector_registry(connector_key,connector_type,display_name,object_type,contract_version,active)
VALUES
 ('salesforce_primary','salesforce','Salesforce Opportunities','deal',1,false),
 ('airtable_primary','airtable','Airtable Opportunities','deal',1,false)
ON CONFLICT (connector_key) DO UPDATE SET
 connector_type=EXCLUDED.connector_type, display_name=EXCLUDED.display_name,
 object_type=EXCLUDED.object_type, contract_version=EXCLUDED.contract_version, updated_at=now();

INSERT INTO governance.connector_runtime_config(
 connector_key,provider_available,credential_validated,read_enabled,write_enabled,blocked_reason,provider_config
)
VALUES
 ('salesforce_primary',false,false,false,false,'DEDICATED_CREDENTIAL_REQUIRED','{}'::jsonb),
 ('airtable_primary',false,false,false,false,'AIRTABLE_API_BILLING_LIMIT',
  jsonb_build_object('base_id','appJWBEYJNpG3PxpN','opportunities_table_id','tblhdLg6Ipfw4hsUp',
    'won_stages',jsonb_build_array('Closed Won'),'lost_stages',jsonb_build_array('Closed Lost')))
ON CONFLICT (connector_key) DO NOTHING;

DELETE FROM governance.connector_field_mapping
WHERE connector_key IN ('salesforce_primary','airtable_primary');

INSERT INTO governance.connector_field_mapping
(connector_key,canonical_field,source_field,transform_key,required,default_value)
VALUES
 ('salesforce_primary','deal_name','Name','text',false,NULL),
 ('salesforce_primary','amount','Amount','numeric',true,NULL),
 ('salesforce_primary','currency_code','CurrencyIsoCode','uppercase',true,NULL),
 ('salesforce_primary','stage_name','StageName','text',true,NULL),
 ('salesforce_primary','stage_category','revint_stage_category','text',true,NULL),
 ('salesforce_primary','sales_rep','OwnerId','text',false,NULL),
 ('salesforce_primary','lead_source','LeadSource','text',false,NULL),
 ('salesforce_primary','created_at','CreatedDate','timestamp',false,NULL),
 ('salesforce_primary','expected_close_date','CloseDate','timestamp',false,NULL),
 ('salesforce_primary','closed_at','CloseDate','timestamp',false,NULL),
 ('salesforce_primary','source_updated_at','LastModifiedDate','timestamp',false,NULL),
 ('airtable_primary','deal_name','Opportunity Name','text',false,NULL),
 ('airtable_primary','amount','Deal Value','numeric',true,NULL),
 ('airtable_primary','currency_code','revint_currency_code','uppercase',true,NULL),
 ('airtable_primary','stage_name','Stage','text',true,NULL),
 ('airtable_primary','stage_category','revint_stage_category','text',true,NULL);

INSERT INTO governance.reliability_policy(
 component_key,workflow_id,display_name,max_attempts,retry_delay_ms,circuit_failure_threshold,
 circuit_open_seconds,half_open_probe_seconds,active
)
VALUES
 ('salesforce_sync','REVINTV2SALESFORCE01','Salesforce opportunity synchronization',3,2000,3,600,60,false),
 ('airtable_sync','REVINTV2AIRTABLE01','Airtable opportunity synchronization',3,2000,3,600,60,false)
ON CONFLICT (component_key) DO UPDATE SET
 workflow_id=EXCLUDED.workflow_id, display_name=EXCLUDED.display_name,
 max_attempts=EXCLUDED.max_attempts, retry_delay_ms=EXCLUDED.retry_delay_ms,
 circuit_failure_threshold=EXCLUDED.circuit_failure_threshold,
 circuit_open_seconds=EXCLUDED.circuit_open_seconds,
 half_open_probe_seconds=EXCLUDED.half_open_probe_seconds;

CREATE OR REPLACE FUNCTION governance.get_external_deal_sync_context(
 p_connector_key text, p_component_key text, p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,governance
AS $$
DECLARE
 v_connector governance.connector_registry%ROWTYPE;
 v_runtime governance.connector_runtime_config%ROWTYPE;
 v_state governance.connector_sync_state%ROWTYPE;
 v_currency text; v_start timestamptz; v_gate jsonb; v_allowed boolean;
BEGIN
 SELECT * INTO v_connector FROM governance.connector_registry
 WHERE connector_key=p_connector_key AND object_type='deal' AND contract_version=1;
 IF NOT FOUND THEN RAISE EXCEPTION 'CONNECTOR_NOT_CONFIGURED: %',p_connector_key; END IF;

 INSERT INTO governance.connector_runtime_config(connector_key) VALUES(p_connector_key)
 ON CONFLICT(connector_key) DO NOTHING;
 SELECT * INTO v_runtime FROM governance.connector_runtime_config WHERE connector_key=p_connector_key;

 INSERT INTO governance.connector_sync_state(connector_key) VALUES(p_connector_key)
 ON CONFLICT(connector_key) DO NOTHING;
 SELECT * INTO v_state FROM governance.connector_sync_state WHERE connector_key=p_connector_key;

 SELECT trim(both FROM currency_code::text) INTO v_currency
 FROM governance.business_config ORDER BY updated_at DESC LIMIT 1;
 v_start:=COALESCE(v_state.watermark-make_interval(secs=>v_state.overlap_seconds),
                   p_as_of-make_interval(days=>v_state.initial_lookback_days));
 v_allowed:=v_connector.active AND v_runtime.provider_available
   AND v_runtime.credential_validated AND v_runtime.read_enabled;

 IF v_allowed THEN
   v_gate:=governance.acquire_runtime_gate(p_component_key,p_as_of);
 ELSE
   v_gate:=jsonb_build_object('allowed',false,'component_key',p_component_key,
     'reason',COALESCE(v_runtime.blocked_reason,'CONNECTOR_NOT_READY'));
 END IF;

 RETURN jsonb_build_object(
   'connector_key',v_connector.connector_key,'connector_type',v_connector.connector_type,
   'currency_code',v_currency,'query_start_at',v_start,'query_end_at',p_as_of,
   'watermark',v_state.watermark,'provider_config',v_runtime.provider_config,
   'reliability_gate',v_gate
 );
END;
$$;

REVOKE ALL ON FUNCTION governance.get_external_deal_sync_context(text,text,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION governance.get_external_deal_sync_context(text,text,timestamptz) TO revint_reporting_ro;
GRANT SELECT ON governance.connector_runtime_config TO revint_governance_ro;


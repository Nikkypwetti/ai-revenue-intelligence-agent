\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS governance.incident_notification_config (
  config_id integer PRIMARY KEY DEFAULT 1 CHECK (config_id = 1),
  enabled boolean NOT NULL DEFAULT false,
  provider text NOT NULL DEFAULT 'slack' CHECK (provider IN ('slack')),
  destination_id text,
  destination_name text,
  min_severity text NOT NULL DEFAULT 'warning' CHECK (min_severity IN ('warning','critical')),
  cooldown_seconds integer NOT NULL DEFAULT 3600 CHECK (cooldown_seconds BETWEEN 300 AND 86400),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO governance.incident_notification_config(config_id)
VALUES (1)
ON CONFLICT (config_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS audit.incident_notification_state (
  alert_key text PRIMARY KEY,
  last_severity text NOT NULL CHECK (last_severity IN ('warning','critical')),
  last_notified_at timestamptz NOT NULL,
  provider text NOT NULL,
  destination_name text,
  message_ref text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON governance.incident_notification_config FROM PUBLIC;
REVOKE ALL ON audit.incident_notification_state FROM PUBLIC;

CREATE OR REPLACE FUNCTION observability.get_pending_incident_notifications(
  p_as_of timestamptz DEFAULT now()
)
RETURNS TABLE (
  alert_key text,
  component_key text,
  severity text,
  alert_type text,
  summary text,
  first_observed_at timestamptz,
  context jsonb,
  provider text,
  destination_id text,
  destination_name text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, observability, governance, audit
AS $$
  WITH cfg AS (
    SELECT *
    FROM governance.incident_notification_config
    WHERE config_id = 1
      AND enabled
      AND destination_id IS NOT NULL
      AND btrim(destination_id) <> ''
  ),
  candidates AS (
    SELECT
      a.*,
      c.provider,
      c.destination_id,
      c.destination_name,
      c.cooldown_seconds,
      s.last_severity,
      s.last_notified_at,
      CASE a.severity WHEN 'critical' THEN 2 ELSE 1 END AS current_rank,
      CASE s.last_severity WHEN 'critical' THEN 2 WHEN 'warning' THEN 1 ELSE 0 END AS previous_rank
    FROM observability.alert_ready a
    CROSS JOIN cfg c
    LEFT JOIN audit.incident_notification_state s
      ON s.alert_key = a.alert_key
    WHERE
      CASE c.min_severity WHEN 'critical' THEN a.severity = 'critical'
                          ELSE a.severity IN ('warning','critical') END
  )
  SELECT
    c.alert_key,
    c.component_key,
    c.severity,
    c.alert_type,
    c.summary,
    c.first_observed_at,
    c.context,
    c.provider,
    c.destination_id,
    c.destination_name
  FROM candidates c
  WHERE c.last_notified_at IS NULL
     OR c.current_rank > c.previous_rank
     OR c.last_notified_at <= p_as_of - make_interval(secs => c.cooldown_seconds)
  ORDER BY
    CASE c.severity WHEN 'critical' THEN 1 ELSE 2 END,
    c.first_observed_at,
    c.alert_key;
$$;

CREATE OR REPLACE FUNCTION governance.record_incident_notification_success(
  p_event_id text,
  p_alert_key text,
  p_severity text,
  p_provider text,
  p_message_ref text DEFAULT NULL,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance, observability, audit
AS $$
DECLARE
  v_cfg governance.incident_notification_config%ROWTYPE;
  v_alert record;
  v_audit jsonb;
BEGIN
  SELECT * INTO v_cfg
  FROM governance.incident_notification_config
  WHERE config_id = 1
    AND enabled;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INCIDENT_NOTIFICATION_DISABLED';
  END IF;

  IF p_provider <> v_cfg.provider THEN
    RAISE EXCEPTION 'INCIDENT_PROVIDER_MISMATCH';
  END IF;

  SELECT * INTO v_alert
  FROM observability.alert_ready
  WHERE alert_key = p_alert_key
    AND severity = p_severity;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INCIDENT_ALERT_NOT_ACTIVE';
  END IF;

  INSERT INTO audit.incident_notification_state(
    alert_key,last_severity,last_notified_at,provider,destination_name,message_ref,updated_at
  )
  VALUES (
    p_alert_key,p_severity,p_as_of,p_provider,v_cfg.destination_name,
    NULLIF(left(coalesce(p_message_ref,''),200),''),p_as_of
  )
  ON CONFLICT (alert_key) DO UPDATE SET
    last_severity=EXCLUDED.last_severity,
    last_notified_at=EXCLUDED.last_notified_at,
    provider=EXCLUDED.provider,
    destination_name=EXCLUDED.destination_name,
    message_ref=EXCLUDED.message_ref,
    updated_at=EXCLUDED.updated_at;

  v_audit := governance.record_reliable_audit_event(
    p_event_id,
    NULL,
    NULL,
    'incident_notification_delivered',
    'incident_notification',
    'n8n_incident_notification',
    jsonb_build_object(
      'alert_key',p_alert_key,
      'severity',p_severity,
      'provider',p_provider,
      'destination_name',v_cfg.destination_name,
      'status','delivered'
    ),
    'incident_notifications',
    p_as_of
  );

  RETURN jsonb_build_object(
    'status','recorded',
    'alert_key',p_alert_key,
    'severity',p_severity,
    'provider',p_provider,
    'audit',v_audit
  );
END;
$$;

REVOKE ALL ON FUNCTION observability.get_pending_incident_notifications(timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.record_incident_notification_success(text,text,text,text,text,timestamptz) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION observability.get_pending_incident_notifications(timestamptz)
TO revint_governance_ro;

GRANT EXECUTE ON FUNCTION governance.record_incident_notification_success(text,text,text,text,text,timestamptz)
TO revint_audit_insert;

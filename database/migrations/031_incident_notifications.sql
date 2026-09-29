\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS governance.incident_notification_state (
  alert_fingerprint text PRIMARY KEY
    CHECK (alert_fingerprint ~ '^[0-9a-f]{32}$'),
  last_notified_at timestamptz NOT NULL,
  notification_count integer NOT NULL DEFAULT 1 CHECK (notification_count >= 1),
  last_provider text NOT NULL CHECK (last_provider IN ('slack','email')),
  last_destination_key text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON governance.incident_notification_state FROM PUBLIC;

CREATE OR REPLACE FUNCTION governance.get_pending_incident_notifications(
  p_limit integer DEFAULT 20,
  p_cooldown_minutes integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, governance, observability
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'INCIDENT_NOTIFICATION_LIMIT_INVALID';
  END IF;
  IF p_cooldown_minutes < 5 OR p_cooldown_minutes > 1440 THEN
    RAISE EXCEPTION 'INCIDENT_NOTIFICATION_COOLDOWN_INVALID';
  END IF;

  SELECT COALESCE(jsonb_agg(x.item ORDER BY x.ordinality), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      row_number() OVER () AS ordinality,
      jsonb_build_object(
        'fingerprint', md5(to_jsonb(a)::text),
        'alert', to_jsonb(a)
      ) AS item
    FROM observability.alert_ready a
    LEFT JOIN governance.incident_notification_state s
      ON s.alert_fingerprint = md5(to_jsonb(a)::text)
    WHERE s.last_notified_at IS NULL
       OR s.last_notified_at <= now() - make_interval(mins => p_cooldown_minutes)
    LIMIT p_limit
  ) x;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION governance.get_incident_notification_context(
  p_limit integer DEFAULT 20,
  p_cooldown_minutes integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $
DECLARE
  v_gate jsonb;
  v_notifications jsonb;
BEGIN
  v_gate := governance.acquire_runtime_gate('incident_notification', now());

  IF COALESCE((v_gate->>'allowed')::boolean,false) THEN
    v_notifications := governance.get_pending_incident_notifications(
      p_limit,p_cooldown_minutes
    );
  ELSE
    v_notifications := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'reliability_gate',v_gate,
    'notifications',v_notifications,
    'generated_at',now()
  );
END;
$;

CREATE OR REPLACE FUNCTION governance.record_incident_notification(
  p_event_id text,
  p_notifications jsonb,
  p_provider text,
  p_destination_key text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
DECLARE
  v_item jsonb;
  v_fingerprint text;
  v_count integer := 0;
  v_audit jsonb;
BEGIN
  IF NULLIF(btrim(COALESCE(p_event_id,'')),'') IS NULL
     OR length(p_event_id) > 200 THEN
    RAISE EXCEPTION 'INCIDENT_EVENT_ID_INVALID';
  END IF;

  IF p_provider NOT IN ('slack','email') THEN
    RAISE EXCEPTION 'INCIDENT_PROVIDER_INVALID';
  END IF;

  IF jsonb_typeof(p_notifications) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_notifications) > 100 THEN
    RAISE EXCEPTION 'INCIDENT_NOTIFICATION_BATCH_INVALID';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_notifications)
  LOOP
    v_fingerprint := lower(btrim(COALESCE(v_item->>'fingerprint','')));
    IF v_fingerprint !~ '^[0-9a-f]{32}$' THEN
      RAISE EXCEPTION 'INCIDENT_FINGERPRINT_INVALID';
    END IF;

    INSERT INTO governance.incident_notification_state(
      alert_fingerprint,last_notified_at,notification_count,
      last_provider,last_destination_key,updated_at
    )
    VALUES (
      v_fingerprint,now(),1,p_provider,NULLIF(btrim(COALESCE(p_destination_key,'')),''),now()
    )
    ON CONFLICT (alert_fingerprint) DO UPDATE SET
      last_notified_at=EXCLUDED.last_notified_at,
      notification_count=governance.incident_notification_state.notification_count+1,
      last_provider=EXCLUDED.last_provider,
      last_destination_key=EXCLUDED.last_destination_key,
      updated_at=now();

    v_count := v_count + 1;
  END LOOP;

  v_audit := governance.record_reliable_audit_event(
    p_event_id,
    NULL,
    NULL,
    'incident_notification_sent',
    'incident_notification',
    'n8n_incident_adapter',
    jsonb_build_object(
      'provider',p_provider,
      'destination_key',NULLIF(btrim(COALESCE(p_destination_key,'')),''),
      'alert_count',v_count,
      'status','delivered'
    ),
    NULL
  );

  RETURN jsonb_build_object(
    'status','recorded',
    'provider',p_provider,
    'alert_count',v_count,
    'audit',v_audit
  );
END;
$$;

REVOKE ALL ON FUNCTION governance.get_pending_incident_notifications(integer,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.get_incident_notification_context(integer,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.record_incident_notification(text,jsonb,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION governance.get_incident_notification_context(integer,integer)
TO revint_governance_ro;

GRANT EXECUTE ON FUNCTION governance.record_incident_notification(text,jsonb,text,text)
TO revint_audit_insert;

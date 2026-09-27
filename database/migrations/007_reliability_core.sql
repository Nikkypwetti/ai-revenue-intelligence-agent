\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS governance.reliability_policy (
  component_key text PRIMARY KEY,
  workflow_id text NOT NULL UNIQUE,
  display_name text NOT NULL,
  max_attempts smallint NOT NULL DEFAULT 3 CHECK (max_attempts BETWEEN 1 AND 5),
  retry_delay_ms integer NOT NULL DEFAULT 2000 CHECK (retry_delay_ms BETWEEN 250 AND 60000),
  circuit_failure_threshold smallint NOT NULL DEFAULT 3
    CHECK (circuit_failure_threshold BETWEEN 1 AND 20),
  circuit_open_seconds integer NOT NULL DEFAULT 300
    CHECK (circuit_open_seconds BETWEEN 10 AND 86400),
  half_open_probe_seconds integer NOT NULL DEFAULT 60
    CHECK (half_open_probe_seconds BETWEEN 5 AND 3600),
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS governance.circuit_state (
  component_key text PRIMARY KEY
    REFERENCES governance.reliability_policy(component_key)
    ON DELETE CASCADE,
  state text NOT NULL DEFAULT 'closed'
    CHECK (state IN ('closed','open','half_open')),
  consecutive_failures integer NOT NULL DEFAULT 0
    CHECK (consecutive_failures >= 0),
  opened_at timestamptz,
  reopen_after timestamptz,
  probe_started_at timestamptz,
  last_failure_at timestamptz,
  last_success_at timestamptz,
  last_error_type text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit.runtime_failures (
  failure_id text PRIMARY KEY,
  idempotency_key text NOT NULL UNIQUE,
  incident_id text NOT NULL,
  component_key text NOT NULL,
  workflow_id text NOT NULL,
  workflow_name text,
  execution_id text NOT NULL,
  retry_of_execution_id text,
  node_name text NOT NULL,
  error_type text NOT NULL,
  error_name text,
  error_code text,
  error_message text NOT NULL,
  http_status integer CHECK (http_status BETWEEN 100 AND 599),
  retryable boolean NOT NULL,
  retry_budget_exhausted boolean NOT NULL DEFAULT true,
  classification_reason text NOT NULL,
  failure_context jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_typeof(failure_context) = 'object')
);

CREATE TABLE IF NOT EXISTS audit.dead_letter (
  dead_letter_id text PRIMARY KEY,
  incident_id text NOT NULL UNIQUE,
  failure_id text NOT NULL UNIQUE
    REFERENCES audit.runtime_failures(failure_id)
    ON DELETE CASCADE,
  component_key text NOT NULL,
  workflow_id text NOT NULL,
  execution_id text NOT NULL,
  terminal_reason text NOT NULL,
  dead_letter_status text NOT NULL DEFAULT 'open'
    CHECK (dead_letter_status IN ('open','resolved','discarded')),
  payload_reference jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  CHECK (jsonb_typeof(payload_reference) = 'object')
);

CREATE OR REPLACE FUNCTION governance.classify_runtime_error(
  p_failure jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, governance
AS $$
DECLARE
  v_message text := lower(coalesce(p_failure->>'error_message',''));
  v_name text := lower(coalesce(p_failure->>'error_name',''));
  v_code text := lower(coalesce(p_failure->>'error_code',''));
  v_combined text;
  v_http integer := NULL;
  v_type text := 'unknown';
  v_retryable boolean := false;
  v_reason text := 'No approved deterministic retry classification matched.';
BEGIN
  IF jsonb_typeof(p_failure) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'RUNTIME_FAILURE_OBJECT_REQUIRED';
  END IF;

  IF coalesce(p_failure->>'http_status','') ~ '^[1-5][0-9][0-9]$' THEN
    v_http := (p_failure->>'http_status')::integer;
  END IF;

  v_combined := v_message || ' ' || v_name || ' ' || v_code;

  IF v_http IN (401,403)
     OR v_combined ~ '(unauthori|forbidden|permission denied|access denied|invalid credential|authentication)' THEN
    v_type := 'authentication_or_permission';
    v_reason := 'Authentication and permission failures require manual correction and are not retried.';
  ELSIF v_http = 429
     OR v_combined ~ '(rate limit|too many requests)' THEN
    v_type := 'rate_limit';
    v_retryable := true;
    v_reason := 'Rate limiting may recover after bounded retry delay.';
  ELSIF v_http IN (408,504)
     OR v_combined ~ '(timeout|timed out|etimedout)' THEN
    v_type := 'timeout';
    v_retryable := true;
    v_reason := 'Timeout failures may be transient.';
  ELSIF (v_http BETWEEN 500 AND 599)
     OR v_combined ~ '(econnreset|econnrefused|enotfound|network|socket hang up|service unavailable|bad gateway)' THEN
    v_type := 'network_or_upstream';
    v_retryable := true;
    v_reason := 'Network or upstream-service failures may be transient.';
  ELSIF v_combined ~ '(connection terminated|connection reset|could not connect|too many connections|server closed the connection)' THEN
    v_type := 'database_transient';
    v_retryable := true;
    v_reason := 'Transient database connectivity failures may recover within the bounded retry budget.';
  ELSIF (v_http BETWEEN 400 AND 499)
     OR v_combined ~ '(validation|invalid input|constraint|not null|check violation|foreign key)' THEN
    v_type := 'validation_or_contract';
    v_reason := 'Validation and contract failures require input or configuration correction.';
  END IF;

  RETURN jsonb_build_object(
    'error_type',v_type,
    'retryable',v_retryable,
    'http_status',v_http,
    'classification_reason',v_reason
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.acquire_runtime_gate(
  p_component_key text,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
DECLARE
  v_policy governance.reliability_policy%ROWTYPE;
  v_state governance.circuit_state%ROWTYPE;
  v_retry_after timestamptz;
BEGIN
  SELECT *
  INTO v_policy
  FROM governance.reliability_policy
  WHERE component_key = p_component_key
    AND active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RELIABILITY_POLICY_NOT_FOUND: %', p_component_key;
  END IF;

  INSERT INTO governance.circuit_state (component_key)
  VALUES (p_component_key)
  ON CONFLICT (component_key) DO NOTHING;

  SELECT *
  INTO v_state
  FROM governance.circuit_state
  WHERE component_key = p_component_key
  FOR UPDATE;

  IF v_state.state = 'closed' THEN
    RETURN jsonb_build_object(
      'allowed',true,
      'state','closed',
      'probe',false,
      'max_attempts',v_policy.max_attempts,
      'retry_delay_ms',v_policy.retry_delay_ms
    );
  END IF;

  IF v_state.state = 'open' THEN
    IF v_state.reopen_after IS NOT NULL
       AND v_state.reopen_after > p_as_of THEN
      RETURN jsonb_build_object(
        'allowed',false,
        'state','open',
        'probe',false,
        'retry_after',v_state.reopen_after
      );
    END IF;

    UPDATE governance.circuit_state
    SET
      state = 'half_open',
      probe_started_at = p_as_of,
      updated_at = p_as_of
    WHERE component_key = p_component_key;

    RETURN jsonb_build_object(
      'allowed',true,
      'state','half_open',
      'probe',true,
      'probe_expires_at',
        p_as_of + make_interval(secs => v_policy.half_open_probe_seconds)
    );
  END IF;

  v_retry_after :=
    coalesce(v_state.probe_started_at,p_as_of)
    + make_interval(secs => v_policy.half_open_probe_seconds);

  IF v_retry_after <= p_as_of THEN
    UPDATE governance.circuit_state
    SET
      probe_started_at = p_as_of,
      updated_at = p_as_of
    WHERE component_key = p_component_key;

    RETURN jsonb_build_object(
      'allowed',true,
      'state','half_open',
      'probe',true,
      'probe_expires_at',
        p_as_of + make_interval(secs => v_policy.half_open_probe_seconds)
    );
  END IF;

  RETURN jsonb_build_object(
    'allowed',false,
    'state','half_open',
    'probe',false,
    'retry_after',v_retry_after
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.record_runtime_success(
  p_component_key text,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM governance.reliability_policy
    WHERE component_key = p_component_key
      AND active
  ) THEN
    RAISE EXCEPTION 'RELIABILITY_POLICY_NOT_FOUND: %', p_component_key;
  END IF;

  INSERT INTO governance.circuit_state (
    component_key,state,consecutive_failures,last_success_at,updated_at
  )
  VALUES (
    p_component_key,'closed',0,p_as_of,p_as_of
  )
  ON CONFLICT (component_key) DO UPDATE SET
    state = 'closed',
    consecutive_failures = 0,
    opened_at = NULL,
    reopen_after = NULL,
    probe_started_at = NULL,
    last_success_at = EXCLUDED.last_success_at,
    last_error_type = NULL,
    updated_at = EXCLUDED.updated_at;

  RETURN jsonb_build_object(
    'component_key',p_component_key,
    'state','closed',
    'consecutive_failures',0,
    'recorded_at',p_as_of
  );
END;
$$;

CREATE OR REPLACE FUNCTION governance.record_terminal_failure(
  p_failure jsonb,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance, audit
AS $$
DECLARE
  v_component text := btrim(coalesce(p_failure->>'component_key',''));
  v_workflow_id text := btrim(coalesce(p_failure->>'workflow_id',''));
  v_execution_id text := btrim(coalesce(p_failure->>'execution_id',''));
  v_node_name text := left(btrim(coalesce(p_failure->>'node_name','Unknown Node')),200);
  v_policy governance.reliability_policy%ROWTYPE;
  v_class jsonb;
  v_idempotency text;
  v_failure_id text;
  v_incident_id text;
  v_dead_letter_id text;
  v_inserted text;
  v_failures integer;
  v_new_state text;
  v_reopen_after timestamptz;
  v_terminal_reason text;
  v_message text;
BEGIN
  IF jsonb_typeof(p_failure) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'RUNTIME_FAILURE_OBJECT_REQUIRED';
  END IF;

  IF v_component = '' OR v_workflow_id = '' OR v_execution_id = '' THEN
    RAISE EXCEPTION 'RUNTIME_FAILURE_IDENTITY_REQUIRED';
  END IF;

  SELECT *
  INTO v_policy
  FROM governance.reliability_policy
  WHERE component_key = v_component
    AND workflow_id = v_workflow_id
    AND active;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status','ignored',
      'reason','UNMANAGED_WORKFLOW',
      'component_key',nullif(v_component,''),
      'workflow_id',nullif(v_workflow_id,'')
    );
  END IF;

  v_class := governance.classify_runtime_error(p_failure);

  v_message := left(
    regexp_replace(
      coalesce(p_failure->>'error_message','Unknown workflow failure'),
      '[[:cntrl:]]',
      ' ',
      'g'
    ),
    1000
  );

  v_idempotency := md5(
    v_component || '|' ||
    v_workflow_id || '|' ||
    v_execution_id || '|' ||
    v_node_name
  );
  v_failure_id := 'FAIL-' || upper(substr(v_idempotency,1,20));
  v_incident_id := 'INC-' || upper(substr(md5(v_idempotency || '|incident'),1,20));
  v_dead_letter_id := 'DLQ-' || upper(substr(md5(v_idempotency || '|dead-letter'),1,20));

  INSERT INTO audit.runtime_failures (
    failure_id,idempotency_key,incident_id,
    component_key,workflow_id,workflow_name,
    execution_id,retry_of_execution_id,node_name,
    error_type,error_name,error_code,error_message,http_status,
    retryable,retry_budget_exhausted,classification_reason,
    failure_context,created_at
  )
  VALUES (
    v_failure_id,v_idempotency,v_incident_id,
    v_component,v_workflow_id,left(p_failure->>'workflow_name',200),
    v_execution_id,nullif(left(p_failure->>'retry_of_execution_id',200),''),
    v_node_name,
    v_class->>'error_type',
    nullif(left(p_failure->>'error_name',200),''),
    nullif(left(p_failure->>'error_code',200),''),
    v_message,
    CASE
      WHEN coalesce(v_class->>'http_status','') ~ '^[1-5][0-9][0-9]$'
      THEN (v_class->>'http_status')::integer
      ELSE NULL
    END,
    (v_class->>'retryable')::boolean,
    true,
    v_class->>'classification_reason',
    jsonb_build_object(
      'occurred_at',p_failure->>'occurred_at',
      'retry_of_execution_id',p_failure->>'retry_of_execution_id',
      'workflow_name',p_failure->>'workflow_name',
      'node_name',v_node_name
    ),
    p_as_of
  )
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING failure_id INTO v_inserted;

  IF v_inserted IS NULL THEN
    SELECT failure_id, incident_id
    INTO v_failure_id, v_incident_id
    FROM audit.runtime_failures
    WHERE idempotency_key = v_idempotency;

    RETURN jsonb_build_object(
      'status','duplicate_ignored',
      'failure_id',v_failure_id,
      'incident_id',v_incident_id,
      'component_key',v_component
    );
  END IF;

  INSERT INTO governance.circuit_state (component_key)
  VALUES (v_component)
  ON CONFLICT (component_key) DO NOTHING;

  SELECT consecutive_failures + 1
  INTO v_failures
  FROM governance.circuit_state
  WHERE component_key = v_component
  FOR UPDATE;

  IF v_failures >= v_policy.circuit_failure_threshold
     OR EXISTS (
       SELECT 1
       FROM governance.circuit_state
       WHERE component_key = v_component
         AND state = 'half_open'
     ) THEN
    v_new_state := 'open';
    v_reopen_after :=
      p_as_of + make_interval(secs => v_policy.circuit_open_seconds);
  ELSE
    v_new_state := 'closed';
    v_reopen_after := NULL;
  END IF;

  UPDATE governance.circuit_state
  SET
    state = v_new_state,
    consecutive_failures = v_failures,
    opened_at = CASE WHEN v_new_state='open' THEN p_as_of ELSE opened_at END,
    reopen_after = v_reopen_after,
    probe_started_at = NULL,
    last_failure_at = p_as_of,
    last_error_type = v_class->>'error_type',
    updated_at = p_as_of
  WHERE component_key = v_component;

  v_terminal_reason := CASE
    WHEN (v_class->>'retryable')::boolean
      THEN 'retry_budget_exhausted'
    ELSE 'non_retryable_terminal_failure'
  END;

  INSERT INTO audit.dead_letter (
    dead_letter_id,incident_id,failure_id,
    component_key,workflow_id,execution_id,
    terminal_reason,dead_letter_status,payload_reference,created_at
  )
  VALUES (
    v_dead_letter_id,v_incident_id,v_failure_id,
    v_component,v_workflow_id,v_execution_id,
    v_terminal_reason,'open',
    jsonb_build_object(
      'node_name',v_node_name,
      'error_type',v_class->>'error_type',
      'retryable',(v_class->>'retryable')::boolean
    ),
    p_as_of
  )
  ON CONFLICT (incident_id) DO NOTHING;

  RETURN jsonb_build_object(
    'status','recorded',
    'failure_id',v_failure_id,
    'incident_id',v_incident_id,
    'dead_letter_id',v_dead_letter_id,
    'component_key',v_component,
    'error_type',v_class->>'error_type',
    'retryable',(v_class->>'retryable')::boolean,
    'retry_budget_exhausted',true,
    'terminal_reason',v_terminal_reason,
    'circuit_state',v_new_state,
    'consecutive_failures',v_failures,
    'reopen_after',v_reopen_after
  );
END;
$$;


CREATE OR REPLACE FUNCTION governance.record_reliable_audit_event(
  p_event_id text,
  p_request_id text,
  p_correlation_id text,
  p_event_type text,
  p_stage text,
  p_actor text,
  p_payload jsonb,
  p_component_key text,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, governance, audit
AS $$
DECLARE
  v_inserted text;
  v_reliability jsonb := NULL;
BEGIN
  IF btrim(coalesce(p_event_id,'')) = ''
     OR length(p_event_id) > 200 THEN
    RAISE EXCEPTION 'AUDIT_EVENT_ID_INVALID';
  END IF;

  IF btrim(coalesce(p_event_type,'')) = ''
     OR length(p_event_type) > 200
     OR btrim(coalesce(p_stage,'')) = ''
     OR length(p_stage) > 200
     OR btrim(coalesce(p_actor,'')) = ''
     OR length(p_actor) > 200 THEN
    RAISE EXCEPTION 'AUDIT_EVENT_METADATA_INVALID';
  END IF;

  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'AUDIT_EVENT_PAYLOAD_OBJECT_REQUIRED';
  END IF;

  IF p_component_key IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM governance.reliability_policy
       WHERE component_key = p_component_key
         AND active
     ) THEN
    RAISE EXCEPTION 'RELIABILITY_POLICY_NOT_FOUND: %', p_component_key;
  END IF;

  INSERT INTO audit.agent_events (
    event_id,request_id,correlation_id,
    event_type,stage,actor,payload,created_at
  )
  VALUES (
    p_event_id,p_request_id,p_correlation_id,
    p_event_type,p_stage,p_actor,p_payload,p_as_of
  )
  ON CONFLICT (event_id) DO NOTHING
  RETURNING event_id INTO v_inserted;

  IF p_component_key IS NOT NULL THEN
    v_reliability :=
      governance.record_runtime_success(p_component_key,p_as_of);
  END IF;

  RETURN jsonb_build_object(
    'audit_status',
      CASE WHEN v_inserted IS NULL
        THEN 'duplicate_ignored'
        ELSE 'recorded'
      END,
    'event_id',p_event_id,
    'reliability',v_reliability
  );
END;
$$;

REVOKE ALL ON FUNCTION governance.classify_runtime_error(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.acquire_runtime_gate(text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.record_runtime_success(text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.record_terminal_failure(jsonb,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION governance.record_reliable_audit_event(text,text,text,text,text,text,jsonb,text,timestamptz) FROM PUBLIC;

GRANT SELECT ON
  governance.reliability_policy,
  governance.circuit_state
TO revint_governance_ro;

GRANT EXECUTE ON FUNCTION governance.acquire_runtime_gate(text,timestamptz)
TO revint_governance_ro;

GRANT USAGE ON SCHEMA governance TO revint_audit_insert;

GRANT EXECUTE ON FUNCTION governance.classify_runtime_error(jsonb)
TO revint_audit_insert;

GRANT EXECUTE ON FUNCTION governance.record_runtime_success(text,timestamptz)
TO revint_audit_insert;

GRANT EXECUTE ON FUNCTION governance.record_terminal_failure(jsonb,timestamptz)
TO revint_audit_insert;

GRANT EXECUTE ON FUNCTION governance.record_reliable_audit_event(text,text,text,text,text,text,jsonb,text,timestamptz)
TO revint_audit_insert;

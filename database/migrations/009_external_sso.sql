BEGIN;

CREATE OR REPLACE FUNCTION governance.resolve_external_principal(
  p_identity_provider text,
  p_external_subject text
)
RETURNS TABLE (
  mapped boolean,
  principal_key text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
  SELECT
    (p.principal_key IS NOT NULL) AS mapped,
    p.principal_key
  FROM (SELECT 1) AS one
  LEFT JOIN LATERAL (
    SELECT pr.principal_key
    FROM governance.principal_registry pr
    WHERE pr.identity_provider = NULLIF(btrim(p_identity_provider), '')
      AND pr.external_subject = NULLIF(btrim(p_external_subject), '')
      AND pr.active
    LIMIT 1
  ) AS p ON true
  WHERE char_length(COALESCE(p_identity_provider, '')) <= 64
    AND char_length(COALESCE(p_external_subject, '')) <= 512;
$$;

REVOKE ALL
ON FUNCTION governance.resolve_external_principal(text,text)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION governance.resolve_external_principal(text,text)
TO revint_reporting_ro;

COMMIT;

-- Migration 23: Ensure feature usage table + upsert are always created for
-- new clients, and back-fill any existing clients that are missing them.
--
-- Root cause: the live install_client_tables function predates migrations 19
-- and 21, so new clients created via provision_client got neither the
-- oracle_feature_usage table nor upsert_oracle_feature_usage.
--
-- Fix 1: Patch provision_client to explicitly call both functions after
--        install_client_tables, so future new clients are always complete.
-- Fix 2: Run install_feature_usage_table + install_feature_usage_upsert for
--        every existing client schema (idempotent — IF NOT EXISTS guards).

-- ── Fix 1: patch provision_client ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION sam_admin.provision_client(
  p_code TEXT,
  p_name TEXT,
  p_contact_email TEXT DEFAULT NULL
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_schema TEXT := 'client_' || p_code;
  v_client_id INTEGER;
BEGIN
  IF p_code !~ '^[a-z0-9_]+$' THEN
    RAISE EXCEPTION 'client_code must be lowercase alphanumeric/underscore only: %', p_code;
  END IF;

  INSERT INTO sam_admin.clients (client_code, client_name, schema_name, contact_email)
  VALUES (p_code, p_name, v_schema, p_contact_email)
  ON CONFLICT (client_code) DO UPDATE
    SET client_name   = EXCLUDED.client_name,
        contact_email = COALESCE(EXCLUDED.contact_email, sam_admin.clients.contact_email)
  RETURNING client_id INTO v_client_id;

  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);
  EXECUTE format(
    'COMMENT ON SCHEMA %I IS %L',
    v_schema,
    format('SAM client schema for %s (id=%s)', p_name, v_client_id)
  );

  PERFORM sam_admin.install_client_tables(v_schema);

  -- Explicitly call feature-usage functions — older install_client_tables
  -- versions (pre-migration 19/21) omit these calls.
  PERFORM sam_admin.install_feature_usage_table(v_schema);
  PERFORM sam_admin.install_feature_usage_upsert(v_schema);

  RETURN format('Client "%s" provisioned. Schema: %s', p_name, v_schema);
END;
$$;

-- ── Fix 2: back-fill all existing client schemas ────────────────────────────
DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN
    SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_feature_usage_table(v_client.schema_name);
    PERFORM sam_admin.install_feature_usage_upsert(v_client.schema_name);
    RAISE NOTICE 'Feature usage objects ensured for %', v_client.schema_name;
  END LOOP;
END;
$$;

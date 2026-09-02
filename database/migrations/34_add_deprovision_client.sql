-- Migration 34: Add deprovision_client function to sam_admin.
--
-- Permanently removes a client: drops their schema (CASCADE) and deletes
-- the row from sam_admin.clients.  Only run this via the app's Delete button
-- or deliberately in psql — it is irreversible.

CREATE OR REPLACE FUNCTION sam_admin.deprovision_client(p_code TEXT)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_schema TEXT;
  v_name   TEXT;
BEGIN
  SELECT schema_name, client_name INTO v_schema, v_name
  FROM sam_admin.clients WHERE client_code = p_code;

  IF v_schema IS NULL THEN
    RAISE EXCEPTION 'Client not found: %', p_code;
  END IF;

  EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', v_schema);
  DELETE FROM sam_admin.clients WHERE client_code = p_code;

  RETURN format('Client "%s" (schema %s) permanently deleted.', v_name, v_schema);
END;
$$;

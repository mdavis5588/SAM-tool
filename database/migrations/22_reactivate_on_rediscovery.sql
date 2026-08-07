-- Migration 22: Re-activate servers/instances on re-discovery
--
-- upsert_oracle_discovery's ON CONFLICT clauses did not include
-- is_active = TRUE, so a server that was removed (is_active=FALSE) and
-- then re-uploaded stayed hidden. This migration re-installs the discovery
-- functions for every client with the corrected logic.

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN
    SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_upsert_functions(v_client.schema_name);
    RAISE NOTICE 'Reinstalled upsert functions for %', v_client.schema_name;
  END LOOP;
END;
$$;

-- Migration 24: Ensure upsert_oracle_discovery reactivates removed servers.
--
-- Migration 22 fixed the ON CONFLICT clause to add is_active = TRUE but
-- failed on first run (wrong function name) and was never successfully
-- re-applied. This migration re-installs install_upsert_functions for all
-- clients so the fix takes effect.
--
-- After this migration, uploading a JSON/CSV for a previously-removed server
-- (is_active=FALSE) will set is_active=TRUE and make it visible again.

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN
    SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_upsert_functions(v_client.schema_name);
    RAISE NOTICE 'Reinstalled upsert functions for %', v_client.schema_name;
  END LOOP;
END;
$$;

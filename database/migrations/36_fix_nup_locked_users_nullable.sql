-- Migration 36: Make nup_locked_users default to 0 if absent from the payload.
--
-- The CSV upload path did not include nup_locked_users in the extended payload,
-- causing a NOT NULL violation in oracle_nup_users.  The app now sends the
-- field, but we also add COALESCE here so older/manual payloads don't fail.
--
-- Apply:
--   psql $DSN -f database/03_client_template_functions.sql
-- (re-applies the full upsert_oracle_extended_discovery function with the fix)
-- Then run this migration to rebuild it in every active client schema:

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN
    SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name
  LOOP
    RAISE NOTICE 'Refreshing upsert functions for schema: %', v_client.schema_name;
    PERFORM sam_admin.install_upsert_functions(v_client.schema_name);
  END LOOP;
  RAISE NOTICE 'Done.';
END;
$$;

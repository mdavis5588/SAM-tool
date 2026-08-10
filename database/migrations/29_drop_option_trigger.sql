-- Migration 29: Drop the broken trg_log_option_change trigger from all client
--              schemas so oracle_options writes succeed unconditionally.
--
-- The live trigger function references columns that no longer exist in
-- discovery_changelog.  Migrations 26-28 attempted to replace the function
-- but the meta-functions used to install it are themselves stale.
-- Dropping the trigger is the safest fix; the changelog can be re-enabled
-- once the schema is fully synchronised.

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_log_option_change ON %I.oracle_options',
      v_client.schema_name
    );
    RAISE NOTICE 'Dropped trg_log_option_change for %', v_client.schema_name;
  END LOOP;
END;
$$;

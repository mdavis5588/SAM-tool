-- Migration 26: Re-install install_extended_views for all client schemas
--
-- The live log_option_change() trigger function references a column
-- "licenses_assigned" that no longer exists (stale live DB function).
-- install_extended_views creates the corrected version of this trigger.
-- Re-running it for every client schema fixes the oracle_options INSERT/UPDATE.

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_extended_views(v_client.schema_name);
    RAISE NOTICE 'Refreshed extended views and triggers for %', v_client.schema_name;
  END LOOP;
END;
$$;

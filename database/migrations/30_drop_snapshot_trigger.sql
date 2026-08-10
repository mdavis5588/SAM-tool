-- Migration 30: Drop the broken trg_snapshot_on_feature_activation trigger
--              from all client schemas.
--
-- This trigger calls sam_admin.notify_feature_activated() ->
-- sam_admin.take_auto_snapshot() which queries the license_position view.
-- That view references a column 'licences_assigned' that no longer exists
-- in the live DB, causing every oracle_options INSERT/UPDATE to fail.

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_snapshot_on_feature_activation ON %I.oracle_options',
      v_client.schema_name
    );
    RAISE NOTICE 'Dropped trg_snapshot_on_feature_activation for %', v_client.schema_name;
  END LOOP;
END;
$$;

-- Migration 22: Re-activate servers/instances on re-discovery;
--              ensure upsert_oracle_feature_usage exists for all clients.
--
-- Fixes:
-- 1. upsert_oracle_discovery ON CONFLICT now sets is_active = TRUE so
--    a removed server re-uploaded via JSON/CSV reappears correctly.
-- 2. install_feature_usage_upsert was not called by provision_client, so
--    clients created after migration 21 lacked upsert_oracle_feature_usage.

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN
    SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_upsert_functions(v_client.schema_name);
    PERFORM sam_admin.install_feature_usage_upsert(v_client.schema_name);
    RAISE NOTICE 'Reinstalled upsert functions for %', v_client.schema_name;
  END LOOP;
END;
$$;

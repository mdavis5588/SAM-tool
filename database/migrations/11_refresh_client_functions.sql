-- Migration 11: Rebuild all client-schema views after product_detail was added
-- to server_csi_map.
--
-- Run this AFTER re-sourcing 03_client_template_functions.sql so the stored
-- functions (install_server_coverage_view etc.) are up to date, then run this
-- script to rebuild the views inside every active client schema.
--
-- Typical apply sequence:
--   psql $DSN -f database/03_client_template_functions.sql
--   psql $DSN -f database/migrations/11_refresh_client_functions.sql

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN
    SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name
  LOOP
    RAISE NOTICE 'Refreshing views for schema: %', v_client.schema_name;
    PERFORM sam_admin.install_license_position_view(v_client.schema_name);
    PERFORM sam_admin.install_license_options_view(v_client.schema_name);
    PERFORM sam_admin.install_server_coverage_view(v_client.schema_name);
    PERFORM sam_admin.install_changelog_objects(v_client.schema_name);
    PERFORM sam_admin.install_upsert_functions(v_client.schema_name);
    PERFORM sam_admin.install_extended_views(v_client.schema_name);
  END LOOP;
  RAISE NOTICE 'Done.';
END;
$$;

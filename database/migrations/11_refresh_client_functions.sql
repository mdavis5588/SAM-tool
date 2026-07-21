-- Migration 11: Rebuild all client-schema views after product_detail was added
-- to server_csi_map.
--
-- The column product_detail was added to the server_csi_map CREATE TABLE
-- statement in install_client_tables() (01_admin_schema.sql) and to the
-- server_csi_coverage view definition in install_server_coverage_view()
-- (03_client_template_functions.sql). The live database may hold stale
-- compiled versions of both functions.
--
-- Typical apply sequence:
--   psql $DSN -f database/01_admin_schema.sql              -- updates install_client_tables()
--   psql $DSN -f database/03_client_template_functions.sql -- updates view installer functions
--   psql $DSN -f database/migrations/11_refresh_client_functions.sql  -- rebuilds views

-- Rebuild all views in every active client schema (including any that were
-- provisioned after 01_admin_schema.sql clobbered the real view-installer
-- functions with empty stubs).
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

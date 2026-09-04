-- Migration 35: Install missing tables in client schemas that were provisioned
-- with an outdated provision_client() that didn't call install_client_tables().
--
-- Apply sequence (run in order against oracle_sam):
--
--   1. psql $DSN -f database/01_admin_schema.sql
--   2. psql $DSN -f database/03_client_template_functions.sql
--   3. psql $DSN -f database/migrations/35_fix_missing_client_tables.sql
--
-- Steps 1-2 update the live function definitions so new clients provision
-- correctly going forward.  Step 3 backfills tables into any existing client
-- schemas that are missing them.

DO $$
DECLARE
  v_client RECORD;
  v_table_count INTEGER;
BEGIN
  FOR v_client IN
    SELECT schema_name, client_name
    FROM sam_admin.clients
    ORDER BY schema_name
  LOOP
    -- Count tables already in this schema
    SELECT COUNT(*) INTO v_table_count
    FROM information_schema.tables
    WHERE table_schema = v_client.schema_name
      AND table_type = 'BASE TABLE';

    -- Always run — install_client_tables is idempotent (IF NOT EXISTS throughout)
    -- and also installs upsert functions and views that may be missing even when
    -- tables already exist.
    RAISE NOTICE 'Running install_client_tables for schema % (%) — % tables already present',
                 v_client.schema_name, v_client.client_name, v_table_count;
    PERFORM sam_admin.install_client_tables(v_client.schema_name);
  END LOOP;
  RAISE NOTICE 'Done.';
END;
$$;

-- Migration 47: Linux OS licensing.
--
-- Adds a standalone OS licensing layer for Red Hat, Oracle Linux and SUSE.
-- Nothing here touches the Oracle tables, enums or views: shared.product_family
-- and shared.license_metric are left exactly as they are, and the only object
-- the two layers have in common is each client's servers(server_id), because a
-- host is a host whatever runs on it.
--
-- New in shared:
--   os_contracts, os_entitlement_lines, os_contract_client_map, os_license_rules
--   plus the enums os_vendor, os_contract_status, os_sharing_policy,
--   os_license_metric, os_support_level
-- New per client schema:
--   os_installations, os_subscription_map, and the os_license_position view
--
-- Prerequisite: load database/02_shared_schema.sql (for the shared tables and
-- the baseline rules), then database/01_admin_schema.sql (or 00_full_schema.sql)
-- and database/03_client_template_functions.sql, so the sam_admin installers
-- exist. This migration only rolls the per-client objects out to clients that
-- already exist; it refuses to run against stale installers rather than
-- reporting success and creating nothing.

DO $MIGR47$
DECLARE
  v_schema TEXT;
  v_n      INTEGER := 0;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'sam_admin' AND p.proname = 'install_os_tables'
  ) THEN
    RAISE EXCEPTION
      'sam_admin.install_os_tables does not exist. Load '
      'database/01_admin_schema.sql (or 00_full_schema.sql) first.';
  END IF;

  -- The stub in 01/00 has an empty body; only 03 supplies the real one.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'sam_admin'
      AND p.proname = 'install_os_license_position_view'
      AND p.prosrc LIKE '%os_license_position%'
  ) THEN
    RAISE EXCEPTION
      'sam_admin.install_os_license_position_view is still the placeholder '
      'stub. Load database/03_client_template_functions.sql first.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'shared' AND table_name = 'os_contracts') THEN
    RAISE EXCEPTION
      'shared.os_contracts does not exist. Load '
      'database/02_shared_schema.sql first.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM shared.os_license_rules WHERE is_active) THEN
    RAISE WARNING
      'shared.os_license_rules is empty, so every installation will report '
      'coverage_status = no_rule. Re-run the rule seed in 02_shared_schema.sql.';
  END IF;

  FOR v_schema IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = v_schema AND table_name = 'servers') THEN
      RAISE NOTICE '% : no servers table, schema not provisioned; skipping', v_schema;
      CONTINUE;
    END IF;

    PERFORM sam_admin.install_os_tables(v_schema);
    PERFORM sam_admin.install_os_license_position_view(v_schema);
    v_n := v_n + 1;
    RAISE NOTICE '% : OS tables and position view installed', v_schema;
  END LOOP;

  RAISE NOTICE 'Migration 47 complete: % schema(s) updated.', v_n;
END
$MIGR47$;

-- Verification: every provisioned schema should report true in all three
-- columns, and rule_count should be non-zero.
SELECT c.schema_name,
       EXISTS (SELECT 1 FROM information_schema.tables t
               WHERE t.table_schema = c.schema_name
                 AND t.table_name = 'os_installations')     AS has_installations,
       EXISTS (SELECT 1 FROM information_schema.tables t
               WHERE t.table_schema = c.schema_name
                 AND t.table_name = 'os_subscription_map')  AS has_subscription_map,
       EXISTS (SELECT 1 FROM information_schema.views v
               WHERE v.table_schema = c.schema_name
                 AND v.table_name = 'os_license_position')  AS has_position_view,
       (SELECT COUNT(*) FROM shared.os_license_rules WHERE is_active) AS rule_count
FROM   sam_admin.clients c
ORDER  BY c.schema_name;

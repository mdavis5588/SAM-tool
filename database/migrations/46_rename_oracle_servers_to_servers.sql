-- Migration 46: Rename oracle_servers to servers in every client schema.
--
-- The table is the server inventory, not an Oracle-specific one: java_installations,
-- mysql_installations and oci_instances already hang off it, and support for Linux
-- and Windows licensing puts hosts in it that run no Oracle at all. The name was
-- becoming actively misleading.
--
-- PostgreSQL tracks view dependencies by OID, so views following the table are
-- carried across by the rename and re-render against the new name by themselves.
-- Functions are not: they build their SQL as text with format(), so every one that
-- names the table has to be redeployed. This migration does both.
--
-- The files in database/migrations/ up to 45 still say oracle_servers on purpose.
-- They are a record of what was applied and must keep working against a database
-- that predates this rename, so run them BEFORE this one, never after.
--
-- Prerequisite: load database/01_admin_schema.sql, database/02_shared_schema.sql
-- and database/03_client_template_functions.sql first, so the sam_admin installers
-- name the new table. This migration refuses to run otherwise, rather than renaming
-- the table and leaving the functions pointing at a name that no longer exists.

DO $MIGR46$
DECLARE
  v_schema  TEXT;
  v_renamed INTEGER := 0;
  v_already INTEGER := 0;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'sam_admin'
      AND  p.proname = 'install_client_tables'
      AND  p.prosrc LIKE '%.servers (%'
  ) THEN
    RAISE EXCEPTION
      'sam_admin.install_client_tables still names oracle_servers. Load '
      'database/01_admin_schema.sql, 02_shared_schema.sql and '
      '03_client_template_functions.sql first, then run this migration.';
  END IF;

  -- This migration redeploys the client functions from the templates, so any fix a
  -- later migration made to those functions is lost unless the template carries it
  -- too. Three do not, as of writing: 33 (oracle_processors ON CONFLICT), 38
  -- (schema-qualified environment_type and virt_type casts) and 39 (skipping an
  -- instance with a null or empty SID). Running this against a database that has
  -- those migrations applied would quietly revert them, so refuse until the
  -- templates are brought current.
  IF NOT EXISTS (
    SELECT 1
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'sam_admin'
      AND  p.proname = 'install_upsert_functions'
      AND  p.prosrc LIKE '%.environment_type%'
  ) THEN
    RAISE EXCEPTION
      'sam_admin.install_upsert_functions predates migration 38: it casts to an '
      'unqualified environment_type. Redeploying from it would also revert '
      'migrations 33 and 39. Fold those three fixes into '
      'database/03_client_template_functions.sql before running this migration.';
  END IF;

  FOR v_schema IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema = v_schema AND table_name = 'servers') THEN
      v_already := v_already + 1;
      RAISE NOTICE '% : already renamed', v_schema;

    ELSIF EXISTS (SELECT 1 FROM information_schema.tables
                  WHERE table_schema = v_schema AND table_name = 'oracle_servers') THEN
      EXECUTE format('ALTER TABLE %I.oracle_servers RENAME TO servers', v_schema);
      v_renamed := v_renamed + 1;
      RAISE NOTICE '% : renamed', v_schema;

    ELSE
      RAISE NOTICE '% : no server table, schema not provisioned; skipping', v_schema;
      CONTINUE;
    END IF;

    -- Redeploy everything that builds SQL as text and so still names the old table.
    PERFORM sam_admin.install_client_tables(v_schema);
    PERFORM sam_admin.install_license_position_view(v_schema);
    PERFORM sam_admin.install_license_options_view(v_schema);
    PERFORM sam_admin.install_server_coverage_view(v_schema);
    PERFORM sam_admin.install_changelog_objects(v_schema);
    PERFORM sam_admin.install_upsert_functions(v_schema);
    PERFORM sam_admin.install_extended_views(v_schema);
  END LOOP;

  RAISE NOTICE 'Migration 46 complete: % renamed, % already done.', v_renamed, v_already;
END
$MIGR46$;

-- Verification: every schema should report has_servers true, has_old false, and a
-- function body that no longer names the old table.
SELECT c.schema_name,
       EXISTS (SELECT 1 FROM information_schema.tables t
               WHERE t.table_schema = c.schema_name AND t.table_name = 'servers')        AS has_servers,
       EXISTS (SELECT 1 FROM information_schema.tables t
               WHERE t.table_schema = c.schema_name AND t.table_name = 'oracle_servers') AS has_old,
       EXISTS (SELECT 1 FROM pg_proc p
               JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = c.schema_name
                 AND p.proname = 'upsert_oracle_discovery'
                 AND p.prosrc LIKE '%oracle_servers%')                                   AS fn_still_stale
FROM   sam_admin.clients c
ORDER  BY c.schema_name;

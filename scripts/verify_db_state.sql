-- Run BEFORE the fixes to see what is missing, and AFTER to confirm.
-- Expect every column true / present once the three scripts have been run.
\pset border 2

\echo '=== 1. Does each client have the nup_sample_users guard? (needs 03 + migration 45) ==='
SELECT n.nspname                                             AS schema,
       p.prosrc LIKE '%NULLIF(v_inst->''nup_sample_users''%'  AS has_nullif_guard,
       p.prosrc LIKE '%requires_multitenant_licence%'         AS has_multitenant_cols
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  p.proname = 'upsert_oracle_extended_discovery'
ORDER  BY n.nspname;

\echo '=== 2. Is the sam_admin installer itself current? (migration 45 refuses if false) ==='
SELECT p.prosrc LIKE '%NULLIF(v_inst->''nup_sample_users''%' AS installer_current
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'sam_admin' AND p.proname = 'install_extended_views';

\echo '=== 3. Which client schemas have discovery_errors? (needs migration 40) ==='
SELECT c.schema_name,
       EXISTS (SELECT 1 FROM information_schema.tables t
               WHERE t.table_schema = c.schema_name
                 AND t.table_name   = 'discovery_errors') AS has_discovery_errors
FROM   sam_admin.clients c
ORDER  BY c.schema_name;

\echo '=== 4. Will the base schema give NEW clients the table? (needs 01_admin_schema.sql) ==='
SELECT p.prosrc LIKE '%discovery_errors%' AS base_schema_creates_it
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'sam_admin' AND p.proname = 'install_client_tables';

\echo '=== 5. Discovery errors recorded in the last 7 days, per client ==='
DO $$
DECLARE
  v_schema TEXT;
  v_row    RECORD;
  v_found  BOOLEAN := FALSE;
BEGIN
  FOR v_schema IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = v_schema AND table_name = 'discovery_errors') THEN
      RAISE NOTICE '% : no discovery_errors table', v_schema;
      CONTINUE;
    END IF;
    FOR v_row IN EXECUTE format(
      'SELECT error_type, COUNT(*) AS n, MAX(recorded_at) AS latest
         FROM %I.discovery_errors
        WHERE recorded_at >= NOW() - INTERVAL ''7 days''
        GROUP BY error_type ORDER BY 2 DESC', v_schema)
    LOOP
      v_found := TRUE;
      RAISE NOTICE '% : % x % (latest %)', v_schema, v_row.n, v_row.error_type, v_row.latest;
    END LOOP;
  END LOOP;
  IF NOT v_found THEN
    RAISE NOTICE 'No discovery errors recorded in the last 7 days.';
  END IF;
END
$$;

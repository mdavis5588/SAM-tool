-- Reports which database fixes a deployment is still missing.
--
-- Plain SQL with no psql backslash commands, so it runs anywhere: psql,
-- pgAdmin, DBeaver, or pasted into a query window. Returns a single result set;
-- every row should read OK, and anything MISSING names the script to run.
--
-- None of the relevant scripts record having been run, so this is the way to
-- tell what a given database actually has.

SELECT * FROM (

  -- The guard that stops "cannot extract elements from a scalar" when Oracle
  -- emits a JSON null for an empty nup_sample_users.
  SELECT 1                                  AS seq,
         'nup_sample_users guard'           AS check_name,
         n.nspname                          AS target,
         CASE WHEN p.prosrc LIKE '%NULLIF(v_inst->''nup_sample_users''%'
              THEN 'OK'
              ELSE 'MISSING -> run 03_client_template_functions.sql, then migration 45'
         END                                AS result
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  p.proname = 'upsert_oracle_extended_discovery'

  UNION ALL

  -- Migration 44 redeploys a body that predates these columns, which the
  -- multitenant view reads. Their absence means 44 was applied.
  SELECT 2,
         'multitenant columns',
         n.nspname,
         CASE WHEN p.prosrc LIKE '%requires_multitenant_licence%'
              THEN 'OK'
              ELSE 'MISSING -> migration 44 was applied; run 03, then migration 45'
         END
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  p.proname = 'upsert_oracle_extended_discovery'

  UNION ALL

  -- Migration 45 reinstalls from this, and refuses to run if it is stale.
  SELECT 3,
         'sam_admin installer current',
         'install_extended_views',
         CASE WHEN COUNT(*) FILTER (
                     WHERE p.prosrc LIKE '%NULLIF(v_inst->''nup_sample_users''%') > 0
              THEN 'OK'
              ELSE 'MISSING -> run 03_client_template_functions.sql'
         END
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'sam_admin'
    AND  p.proname = 'install_extended_views'

  UNION ALL

  -- Without this table the discovery playbooks have nowhere to record an
  -- instance that failed to report.
  SELECT 4,
         'discovery_errors table',
         c.schema_name,
         CASE WHEN EXISTS (
                     SELECT 1 FROM information_schema.tables t
                     WHERE  t.table_schema = c.schema_name
                       AND  t.table_name   = 'discovery_errors')
              THEN 'OK'
              ELSE 'MISSING -> run migration 40'
         END
  FROM   sam_admin.clients c

  UNION ALL

  -- Affects clients provisioned from now on, not existing ones.
  SELECT 5,
         'base schema creates it',
         'install_client_tables',
         CASE WHEN COUNT(*) FILTER (WHERE p.prosrc LIKE '%discovery_errors%') > 0
              THEN 'OK'
              ELSE 'MISSING -> run 01_admin_schema.sql (new clients only)'
         END
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'sam_admin'
    AND  p.proname = 'install_client_tables'

) checks
ORDER BY seq, target;


-- Discovery errors recorded recently. Run separately, editing the schema name,
-- since a plain query cannot reach into each client schema by itself.
--
-- SELECT error_type, COUNT(*) AS n, MAX(recorded_at) AS latest
-- FROM   client_megantest.discovery_errors
-- WHERE  recorded_at >= NOW() - INTERVAL '7 days'
-- GROUP  BY error_type
-- ORDER  BY n DESC;

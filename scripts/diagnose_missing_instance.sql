-- Lists every Oracle instance recorded in every client schema, so you can see
-- what discovery actually wrote without needing to know a hostname or schema.
--
-- Nothing to edit. Plain SQL with no psql backslash commands, so it runs in
-- pgAdmin and DBeaver too. Output arrives as notices: in pgAdmin look at the
-- Messages tab, not the Data Output grid.
--
-- Use it when Ansible clearly collected an instance but the app does not show
-- it: if the SID is listed here the write worked and the problem is display;
-- if it is absent the problem is the write.

DO $DIAG$
DECLARE
  v_schema TEXT;
  v_row    RECORD;
  v_n      INTEGER;
BEGIN
  FOR v_schema IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    RAISE NOTICE '';
    RAISE NOTICE '=== schema % ===', v_schema;

    -- A half-provisioned schema must not abort the whole report.
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = v_schema AND table_name = 'oracle_instances') THEN
      RAISE NOTICE '  no oracle_instances table — schema not provisioned; skipping';
      CONTINUE;
    END IF;

    -- Instances, active or not, with the host they belong to.
    EXECUTE format(
      'SELECT COUNT(*) FROM %I.oracle_instances', v_schema) INTO v_n;
    RAISE NOTICE '  % instance row(s) total', v_n;

    FOR v_row IN EXECUTE format(
      'SELECT s.hostname, i.oracle_sid, COALESCE(i.edition,''(null)'') AS edition,
              COALESCE(i.db_version,''(null)'') AS db_version, i.is_active,
              COALESCE(to_char(i.last_seen,''YYYY-MM-DD HH24:MI''),''never'') AS last_seen
         FROM %I.oracle_instances i
         JOIN %I.oracle_servers   s ON s.server_id = i.server_id
        ORDER BY s.hostname, i.oracle_sid', v_schema, v_schema)
    LOOP
      RAISE NOTICE '  % | % | % | % | active=% | seen %',
        v_row.hostname, v_row.oracle_sid, v_row.edition,
        v_row.db_version, v_row.is_active, v_row.last_seen;
    END LOOP;

    -- Servers with no instance rows at all.
    FOR v_row IN EXECUTE format(
      'SELECT s.hostname
         FROM %I.oracle_servers s
        WHERE NOT EXISTS (SELECT 1 FROM %I.oracle_instances i
                          WHERE i.server_id = s.server_id)
        ORDER BY s.hostname', v_schema, v_schema)
    LOOP
      RAISE NOTICE '  %  <- server row exists but has NO instances', v_row.hostname;
    END LOOP;

    -- Recent discovery failures, if the table is present.
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema = v_schema AND table_name = 'discovery_errors') THEN
      FOR v_row IN EXECUTE format(
        'SELECT hostname, COALESCE(oracle_sid,''-'') AS oracle_sid, error_type,
                LEFT(COALESCE(error_detail,''''),90) AS detail
           FROM %I.discovery_errors
          WHERE recorded_at >= NOW() - INTERVAL ''2 days''
          ORDER BY recorded_at DESC LIMIT 25', v_schema)
      LOOP
        RAISE NOTICE '  ERROR % / % : % — %',
          v_row.hostname, v_row.oracle_sid, v_row.error_type, v_row.detail;
      END LOOP;
    ELSE
      RAISE NOTICE '  (no discovery_errors table — run migration 40)';
    END IF;

    -- What the licence view kept. Fewer rows than instances is expected: it is
    -- DISTINCT ON (server, edition) because the licence is per server, so two
    -- instances on the same edition collapse into one row.
    IF EXISTS (SELECT 1 FROM information_schema.views
               WHERE table_schema = v_schema AND table_name = 'license_position') THEN
      FOR v_row IN EXECUTE format(
        'SELECT hostname, product_family, COALESCE(product_detail,''(null)'') AS product_detail
           FROM %I.license_position
          WHERE product_family = ''oracle_database''
          ORDER BY hostname', v_schema)
      LOOP
        RAISE NOTICE '  licence row: % | % | %',
          v_row.hostname, v_row.product_family, v_row.product_detail;
      END LOOP;
    END IF;
  END LOOP;
END
$DIAG$;

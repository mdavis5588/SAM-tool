-- Finds where an instance discovered by Ansible is being lost before the app.
--
-- EDIT THE TWO PLACEHOLDERS: the hostname below, and replace client_megantest
-- with your client schema throughout (a plain query cannot parameterise a schema).
--
-- Plain SQL, no psql backslash commands, so it runs in pgAdmin or DBeaver too.
-- Run each numbered query separately if your client only shows the last result.

-- 1. Every instance row recorded for the host, active or not.
--    If the 26ai SID is absent here, the write is the problem.
--    If present but is_active = false, something deactivated it.
SELECT i.oracle_sid,
       i.edition,
       i.db_version,
       i.is_active,
       i.db_name,
       i.last_seen,
       i.discovery_run_id
FROM   client_megantest.oracle_instances i
JOIN   client_megantest.oracle_servers   s ON s.server_id = i.server_id
WHERE  s.hostname = '<HOSTNAME>'
ORDER  BY i.oracle_sid;


-- 2. Anything the discovery run recorded as a failure for this host.
--    no_output or unparsable_output here means sqlplus returned nothing usable.
SELECT e.oracle_sid, e.error_type, e.error_detail, e.recorded_at
FROM   client_megantest.discovery_errors e
WHERE  e.hostname = '<HOSTNAME>'
  AND  e.recorded_at >= NOW() - INTERVAL '2 days'
ORDER  BY e.recorded_at DESC;


-- 3. What the licence position view shows for the host.
--    Expect FEWER rows than instances: the view is DISTINCT ON (server, edition),
--    deliberately one row per edition because the licence is per server. Two
--    instances both on Enterprise Edition therefore collapse into one row, and
--    db_version is not part of that key, so the surviving version is arbitrary.
SELECT product_family, product_detail, licence_metric, licences_required
FROM   client_megantest.license_position
WHERE  hostname = '<HOSTNAME>'
ORDER  BY product_family, product_detail;


-- 4. Instances per edition next to what the licence view kept, side by side.
SELECT i.edition,
       COUNT(*)                                        AS instances,
       STRING_AGG(i.oracle_sid || ' (' || COALESCE(i.db_version,'?') || ')',
                  ', ' ORDER BY i.oracle_sid)          AS sids_and_versions
FROM   client_megantest.oracle_instances i
JOIN   client_megantest.oracle_servers   s ON s.server_id = i.server_id
WHERE  s.hostname = '<HOSTNAME>'
  AND  i.is_active
GROUP  BY i.edition
ORDER  BY i.edition;


-- 5. Per-SID options, the Oracle Instances table's source.
SELECT i.oracle_sid, STRING_AGG(o.option_name, ', ' ORDER BY o.option_name) AS options
FROM   client_megantest.oracle_instances i
JOIN   client_megantest.oracle_servers   s ON s.server_id = i.server_id
LEFT   JOIN client_megantest.oracle_options o ON o.instance_id = i.instance_id
WHERE  s.hostname = '<HOSTNAME>'
  AND  i.is_active
GROUP  BY i.oracle_sid
ORDER  BY i.oracle_sid;

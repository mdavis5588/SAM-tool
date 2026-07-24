-- =============================================================================
-- Oracle SAM Discovery Script — CSV output
-- Run with SQL*Plus directly on the Oracle DB server for human-readable output.
--
-- Usage:
--   sqlplus / as sysdba @oracle_discovery_csv.sql
--   sqlplus sam_discovery/<password>@<tns_alias> @oracle_discovery_csv.sql
--
-- Output files (all prefixed with hostname_date):
--   <host>_<date>_server.csv         — server, OS, CPU, RAM
--   <host>_<date>_instances.csv      — Oracle instances and editions
--   <host>_<date>_feature_usage.csv  — DBA_FEATURE_USAGE_STATISTICS (licence-relevant)
--   <host>_<date>_users.csv          — Named User Plus counts
--   <host>_<date>_pdbs.csv           — PDB topology (CDB only)
--   <host>_<date>_rac_nodes.csv      — RAC cluster nodes (RAC only)
--
-- Feature usage comes from DBA_FEATURE_USAGE_STATISTICS, which records actual
-- detected usage counts and dates — the same source Oracle auditors use.
-- =============================================================================

SET TERMOUT OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET HEADING OFF
SET PAGESIZE 0
SET TRIMSPOOL ON
SET LINESIZE 4000
SET COLSEP ','

-- Derive base filename prefix
COLUMN sam_prefix NEW_VALUE sam_prefix NOPRINT
SELECT LOWER(REPLACE(host_name, '.', '_'))
       || '_'
       || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') AS sam_prefix
FROM   v$instance;

-- =============================================================================
-- 1. SERVER — hardware, OS, virtualisation
-- =============================================================================
SPOOL &sam_prefix._server.csv

-- Header
PROMPT hostname,fqdn,os_family,os_platform,db_version,cpu_sockets,cores_per_socket,threads_per_core,total_physical_cores,vcpu_count,ram_mb,cpu_model,virt_type,generated_at

SELECT
  LOWER(i.host_name)                                           AS hostname,
  LOWER(i.host_name)                                           AS fqdn,
  CASE
    WHEN LOWER(d.platform_name) LIKE '%linux%'   THEN 'linux'
    WHEN LOWER(d.platform_name) LIKE '%windows%' THEN 'windows'
    WHEN LOWER(d.platform_name) LIKE '%solaris%' THEN 'solaris'
    WHEN LOWER(d.platform_name) LIKE '%aix%'     THEN 'aix'
    WHEN LOWER(d.platform_name) LIKE '%hp%'      THEN 'hpux'
    ELSE 'unknown'
  END                                                          AS os_family,
  SUBSTR(d.platform_name, 1, 100)                             AS os_platform,
  SUBSTR(i.version, 1, 20)                                    AS db_version,
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_CPU_SOCKETS')      AS cpu_sockets,
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_CORES_PER_SOCKET') AS cores_per_socket,
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_THREADS_PER_CORE') AS threads_per_core,
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_CPU_SOCKETS') *
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_CORES_PER_SOCKET') AS total_physical_cores,
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_CPUS')             AS vcpu_count,
  ROUND((SELECT value FROM v$osstat WHERE stat_name = 'PHYSICAL_MEMORY_BYTES') / 1024 / 1024) AS ram_mb,
  NVL((SELECT SUBSTR(value,1,100) FROM v$parameter WHERE name = 'processor_type'), 'unknown') AS cpu_model,
  'physical'                                                   AS virt_type,
  TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS')                  AS generated_at
FROM v$instance i
CROSS JOIN v$database d;

SPOOL OFF

-- =============================================================================
-- 2. INSTANCES — database name, edition, version, CDB/RAC flags
-- =============================================================================
SPOOL &sam_prefix._instances.csv

PROMPT instance_name,db_name,db_unique_name,edition,version,platform_name,is_cdb,log_mode,node_count

SELECT
  i.instance_name,
  d.name                                                       AS db_name,
  d.db_unique_name,
  SUBSTR(CASE
    WHEN UPPER(v.banner) LIKE '%ENTERPRISE%'         THEN 'Enterprise Edition'
    WHEN UPPER(v.banner) LIKE '%STANDARD EDITION 2%' THEN 'Standard Edition 2'
    WHEN UPPER(v.banner) LIKE '%STANDARD%'           THEN 'Standard Edition'
    WHEN UPPER(v.banner) LIKE '%EXPRESS%'            THEN 'Express Edition'
    ELSE SUBSTR(v.banner, 1, 80)
  END, 1, 60)                                                  AS edition,
  SUBSTR(i.version, 1, 20)                                     AS version,
  SUBSTR(d.platform_name, 1, 80)                              AS platform_name,
  d.cdb                                                        AS is_cdb,
  d.log_mode,
  (SELECT COUNT(*) FROM gv$instance)                          AS node_count
FROM   v$instance i
CROSS  JOIN v$database d
CROSS  JOIN (SELECT banner FROM v$version WHERE UPPER(banner) LIKE '%ORACLE DATABASE%' AND ROWNUM = 1) v;

SPOOL OFF

-- =============================================================================
-- 3. FEATURE USAGE — from DBA_FEATURE_USAGE_STATISTICS
--    This is the primary licence-relevant data set.
--    detected_usages > 0 means Oracle has seen the feature in active use.
--    currently_used = TRUE means it is in use right now (last sample period).
-- =============================================================================
SPOOL &sam_prefix._feature_usage.csv

PROMPT feature_name,db_version,detected_usages,total_samples,currently_used,first_usage_date,last_usage_date,description

SELECT
  '"' || REPLACE(SUBSTR(name, 1, 200), '"', '""') || '"'      AS feature_name,
  SUBSTR(version, 1, 20)                                       AS db_version,
  NVL(detected_usages, 0)                                      AS detected_usages,
  NVL(total_samples, 0)                                        AS total_samples,
  currently_used,
  TO_CHAR(first_usage_date, 'YYYY-MM-DD')                     AS first_usage_date,
  TO_CHAR(last_usage_date,  'YYYY-MM-DD')                     AS last_usage_date,
  '"' || REPLACE(SUBSTR(NVL(description,''), 1, 300), '"', '""') || '"' AS description
FROM   dba_feature_usage_statistics
WHERE  detected_usages > 0
ORDER  BY name;

SPOOL OFF

-- =============================================================================
-- 4. FEATURE USAGE — currently active only (quick licence review view)
--    Same as above but filtered to currently_used = TRUE so you can quickly
--    see what Oracle options are live right now and need to be licenced.
-- =============================================================================
SPOOL &sam_prefix._feature_usage_active.csv

PROMPT feature_name,db_version,detected_usages,total_samples,first_usage_date,last_usage_date,description

SELECT
  '"' || REPLACE(SUBSTR(name, 1, 200), '"', '""') || '"'      AS feature_name,
  SUBSTR(version, 1, 20)                                       AS db_version,
  NVL(detected_usages, 0)                                      AS detected_usages,
  NVL(total_samples, 0)                                        AS total_samples,
  TO_CHAR(first_usage_date, 'YYYY-MM-DD')                     AS first_usage_date,
  TO_CHAR(last_usage_date,  'YYYY-MM-DD')                     AS last_usage_date,
  '"' || REPLACE(SUBSTR(NVL(description,''), 1, 300), '"', '""') || '"' AS description
FROM   dba_feature_usage_statistics
WHERE  currently_used = 'TRUE'
ORDER  BY name;

SPOOL OFF

-- =============================================================================
-- 5. NAMED USER PLUS counts
-- =============================================================================
SPOOL &sam_prefix._users.csv

PROMPT category,user_count

SELECT 'Total non-Oracle users'   AS category, COUNT(*) AS user_count FROM dba_users WHERE oracle_maintained = 'N'
UNION ALL
SELECT 'Active (OPEN)',           COUNT(*) FROM dba_users WHERE oracle_maintained = 'N' AND account_status = 'OPEN'
UNION ALL
SELECT 'Locked',                  COUNT(*) FROM dba_users WHERE oracle_maintained = 'N' AND account_status LIKE '%LOCKED%'
UNION ALL
SELECT 'Expired',                 COUNT(*) FROM dba_users WHERE oracle_maintained = 'N' AND account_status LIKE '%EXPIRED%';

SPOOL OFF

-- =============================================================================
-- 6. PDBs (only populated for CDB databases)
-- =============================================================================
SPOOL &sam_prefix._pdbs.csv

PROMPT pdb_name,con_id,open_mode,restricted

SELECT
  name        AS pdb_name,
  con_id,
  open_mode,
  NVL(restricted, 'NO') AS restricted
FROM   v$pdbs
WHERE  con_id > 0
ORDER  BY con_id;

SPOOL OFF

-- =============================================================================
-- 7. RAC nodes (only populated for RAC databases)
-- =============================================================================
SPOOL &sam_prefix._rac_nodes.csv

PROMPT node_number,instance_name,hostname,status,startup_time

SELECT
  instance_number  AS node_number,
  instance_name,
  LOWER(host_name) AS hostname,
  status,
  TO_CHAR(startup_time, 'YYYY-MM-DD HH24:MI:SS') AS startup_time
FROM   gv$instance
ORDER  BY instance_number;

SPOOL OFF

-- =============================================================================
-- Done
-- =============================================================================
SET TERMOUT ON
SET FEEDBACK ON
SET HEADING ON
SET PAGESIZE 24

PROMPT
PROMPT ============================================================
PROMPT  Discovery complete (CSV).
PROMPT  Files written:
PROMPT    &sam_prefix._server.csv
PROMPT    &sam_prefix._instances.csv
PROMPT    &sam_prefix._feature_usage.csv         (all detected)
PROMPT    &sam_prefix._feature_usage_active.csv  (currently in use)
PROMPT    &sam_prefix._users.csv
PROMPT    &sam_prefix._pdbs.csv                  (CDB only)
PROMPT    &sam_prefix._rac_nodes.csv             (RAC only)
PROMPT ============================================================

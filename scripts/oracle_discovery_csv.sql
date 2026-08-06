-- =============================================================================
-- Oracle SAM Discovery Script — CSV output
-- Implements MOS Doc ID 1317265.1 MAP logic to classify features by product.
-- Run with SQL*Plus directly on the Oracle DB server.
--
-- Usage:
--   sqlplus / as sysdba @oracle_discovery_csv.sql
--   sqlplus sam_discovery/<password>@<tns_alias> @oracle_discovery_csv.sql
--
-- For CDB databases, connect to CDB$ROOT to capture all PDBs.
--
-- Output files (all prefixed with hostname_dbname_date):
--   <host>_<db>_<date>_server.csv              — server, OS, CPU, RAM, virt detection
--   <host>_<db>_<date>_instances.csv           — Oracle instances and editions
--   <host>_<db>_<date>_product_usage.csv       — licence obligation by product (PRIMARY OUTPUT)
--   <host>_<db>_<date>_feature_usage.csv       — CDB-level feature detail with product mapping
--   <host>_<db>_<date>_pdb_feature_usage.csv   — per-PDB feature detail (CDB only)
--   <host>_<db>_<date>_users.csv               — Named User Plus counts
--   <host>_<db>_<date>_pdbs.csv                — PDB topology (name, con_id, open_mode, restricted)
--   <host>_<db>_<date>_rac_nodes.csv           — RAC cluster nodes (RAC only)
--   <host>_<db>_<date>_mgmt_packs.csv          — management pack parameter settings per container
--
-- product_usage.csv is the primary licence review output:
--   CURRENT_USAGE         — used in last sample period; licence required now
--   PAST_OR_CURRENT_USAGE — conditional indicators suggest current or past usage
--   PAST_USAGE            — used historically; review for licence obligation
--   NO_USAGE              — detectable but no usage recorded
--   SUPPRESSED_DUE_TO_BUG — suppressed due to known Oracle defects
--
-- Features marked INVALID in MOS 1317265.1 (system/false-positive) are excluded.
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

COLUMN sam_prefix NEW_VALUE sam_prefix NOPRINT
SELECT LOWER(REPLACE(i.host_name, '.', '_'))
       || '_'
       || LOWER(d.db_unique_name)
       || '_'
       || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') AS sam_prefix
FROM   v$instance i
CROSS  JOIN v$database d;

-- =============================================================================
-- 1. SERVER — hardware, OS, virtualisation
-- =============================================================================
SPOOL &sam_prefix._server.csv

PROMPT hostname,fqdn,os_family,os_platform,db_version,cpu_sockets,cores_per_socket,threads_per_core,total_physical_cores,vcpu_count,ram_mb,cpu_model,virt_type,generated_at

SELECT
  LOWER(i.host_name)                                                      AS hostname,
  LOWER(i.host_name)                                                      AS fqdn,
  CASE
    WHEN LOWER(d.platform_name) LIKE '%linux%'   THEN 'linux'
    WHEN LOWER(d.platform_name) LIKE '%windows%' THEN 'windows'
    WHEN LOWER(d.platform_name) LIKE '%solaris%' THEN 'solaris'
    WHEN LOWER(d.platform_name) LIKE '%aix%'     THEN 'aix'
    WHEN LOWER(d.platform_name) LIKE '%hp%'      THEN 'hpux'
    ELSE 'unknown'
  END                                                                     AS os_family,
  SUBSTR(d.platform_name, 1, 100)                                        AS os_platform,
  SUBSTR(i.version, 1, 20)                                               AS db_version,
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_CPU_SOCKETS')       AS cpu_sockets,
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_CORES_PER_SOCKET')  AS cores_per_socket,
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_THREADS_PER_CORE')  AS threads_per_core,
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_CPU_SOCKETS') *
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_CORES_PER_SOCKET')  AS total_physical_cores,
  (SELECT value FROM v$osstat WHERE stat_name = 'NUM_CPUS')              AS vcpu_count,
  ROUND((SELECT value FROM v$osstat WHERE stat_name = 'PHYSICAL_MEMORY_BYTES') / 1048576) AS ram_mb,
  NVL((SELECT SUBSTR(value,1,100) FROM v$parameter WHERE name = 'processor_type'), 'unknown') AS cpu_model,
  CASE
    WHEN UPPER(NVL((SELECT value FROM v$parameter WHERE name='db_block_checking'),  '')) LIKE '%VMWARE%'
      OR UPPER(NVL((SELECT value FROM v$parameter WHERE name='vm_type'),            '')) LIKE '%VMWARE%'
      OR LOWER(i.host_name) LIKE '%.vmware.%'
      THEN 'vmware'
    WHEN UPPER(NVL((SELECT value FROM v$parameter WHERE name='vm_type'), '')) = 'HVM'
      OR  UPPER(NVL((SELECT value FROM v$parameter WHERE name='vm_type'), '')) LIKE '%ORACLE VM%'
      THEN 'oracle_vm'
    WHEN (SELECT COUNT(*) FROM v$option
          WHERE  UPPER(parameter) = 'OVM' AND value = 'TRUE') > 0
      THEN 'oracle_vm'
    WHEN (SELECT COUNT(*) FROM v$option
          WHERE  UPPER(parameter) LIKE '%VIRTUAL%' AND value = 'TRUE') > 0
      THEN 'virtual'
    ELSE 'physical'
  END                                                                     AS virt_type,
  TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS')                             AS generated_at
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
  d.name                                                                  AS db_name,
  d.db_unique_name,
  SUBSTR(CASE
    WHEN UPPER(v.banner) LIKE '%ENTERPRISE%'          THEN 'Enterprise Edition'
    WHEN UPPER(v.banner) LIKE '%STANDARD EDITION 2%'  THEN 'Standard Edition 2'
    WHEN UPPER(v.banner) LIKE '%STANDARD%'            THEN 'Standard Edition'
    WHEN UPPER(v.banner) LIKE '%EXPRESS%'             THEN 'Express Edition'
    ELSE SUBSTR(v.banner, 1, 80)
  END, 1, 60)                                                             AS edition,
  SUBSTR(i.version, 1, 20)                                               AS version,
  SUBSTR(d.platform_name, 1, 80)                                         AS platform_name,
  d.cdb                                                                   AS is_cdb,
  d.log_mode,
  (SELECT COUNT(*) FROM gv$instance)                                     AS node_count
FROM   v$instance i
CROSS  JOIN v$database d
CROSS  JOIN (SELECT banner FROM v$version
             WHERE  UPPER(banner) LIKE '%ORACLE DATABASE%'
             AND    ROWNUM = 1) v;

SPOOL OFF

-- =============================================================================
-- 3. PRODUCT USAGE — MOS Doc ID 1317265.1 MAP logic
--    Maps DBA_FEATURE_USAGE_STATISTICS to the licensed Oracle product name.
--    This is the PRIMARY licence-review output.
--    INVALID (false-positive/system) entries are excluded by the MAP.
--    BUG entries appear as SUPPRESSED_DUE_TO_BUG.
--    For CDB: connect to CDB$ROOT before running so all PDBs are visible.
-- =============================================================================
SPOOL &sam_prefix._product_usage.csv

PROMPT product,usage_status,first_usage_date,last_usage_date,last_sample_date

WITH
map AS (
  SELECT '' product,'' feature,'' mversion,'' condition FROM dual UNION ALL
  SELECT 'Active Data Guard','Active Data Guard - Real-Time Query on Physical Standby','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Active Data Guard','Global Data Services','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Active Data Guard or Real Application Clusters','Application Continuity','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Analytics','Data Mining','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','ADVANCED Index Compression','^12\.','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','Advanced Index Compression','^12\.','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','Advanced Index Compression','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup HIGH Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup LOW Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup MEDIUM Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup ZLIB Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Data Guard','^11\.2|^1[289]\.|^2[0-9]\.','C001' FROM dual UNION ALL
  SELECT 'Advanced Compression','Flashback Data Archive','^11\.2\.0\.[1-3]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Flashback Data Archive','^(11\.2\.0\.[4-9]\.|1[289]\.|2[0-9]\.)','INVALID' FROM dual UNION ALL
  SELECT 'Advanced Compression','HeapCompression','^11\.2|^12\.1','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','HeapCompression','^12\.[2-9]|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Heat Map','^12\.1','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','Heat Map','^12\.[2-9]|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Hybrid Columnar Compression Row Level Locking','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Information Lifecycle Management','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Oracle Advanced Network Compression Service','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Oracle Utility Datapump (Export)','^11\.2|^1[289]\.|^2[0-9]\.','C001' FROM dual UNION ALL
  SELECT 'Advanced Compression','Oracle Utility Datapump (Import)','^11\.2|^1[289]\.|^2[0-9]\.','C001' FROM dual UNION ALL
  SELECT 'Advanced Compression','SecureFile Compression (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','SecureFile Deduplication (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','ASO native encryption and checksumming','^11\.2|^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Advanced Security','Backup Encryption','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Backup Encryption','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Advanced Security','Data Redaction','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Encrypted Tablespaces','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Oracle Utility Datapump (Export)','^11\.2|^1[289]\.|^2[0-9]\.','C002' FROM dual UNION ALL
  SELECT 'Advanced Security','Oracle Utility Datapump (Import)','^11\.2|^1[289]\.|^2[0-9]\.','C002' FROM dual UNION ALL
  SELECT 'Advanced Security','SecureFile Encryption (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Transparent Data Encryption','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Change Management Pack','Change Management Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Configuration Management Pack for Oracle Database','EM Config Management Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Data Masking Pack','Data Masking Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT '.Database Gateway','Gateways','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Database Gateway','Transparent Gateway','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory ADO Policies','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Aggregation','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Column Store','^12\.1\.0\.2\.','BUG' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Column Store','^12\.1\.0\.[3-9]\.|^12\.2|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Distribute For Service (User Defined)','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Expressions','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory FastStart','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Join Groups','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database Vault','Oracle Database Vault','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database Vault','Privilege Capture','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','ADDM','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','AWR Baseline','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','AWR Baseline Template','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','AWR Report','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Automatic Workload Repository','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Baseline Adaptive Thresholds','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Baseline Static Computations','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Diagnostic Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','EM Performance Page','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Exadata','Cloud DB with EHCC','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Exadata','Exadata','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.GoldenGate','GoldenGate','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression','^12\.1','BUG' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression','^12\.[2-9]|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression Conventional Load','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression Row Level Locking','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','ODA Infrastructure','^1[9]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Sun ZFS with EHCC','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','ZFS Storage','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Zone maps','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Label Security','Label Security','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Multitenant','Oracle Multitenant','^1[28]\.','C003' FROM dual UNION ALL
  SELECT 'Multitenant','Oracle Multitenant','^1[9]\.|^2[0-9]\.','C005' FROM dual UNION ALL
  SELECT 'Multitenant','Oracle Pluggable Databases','^1[28]\.','C003' FROM dual UNION ALL
  SELECT 'OLAP','OLAP - Analytic Workspaces','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'OLAP','OLAP - Cubes','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Partitioning','Partitioning (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Partitioning','Zone maps','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Pillar Storage','Pillar Storage','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Pillar Storage','Pillar Storage with EHCC','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Provisioning and Patch Automation Pack','EM Standalone Provisioning and Patch Automation Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Provisioning and Patch Automation Pack for Database','EM Database Provisioning and Patch Automation Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'RAC or RAC One Node','Quality of Service Management','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Real Application Clusters','Real Application Clusters (RAC)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Real Application Clusters One Node','Real Application Cluster One Node','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Real Application Testing','Database Replay: Workload Capture','^11\.2|^1[289]\.|^2[0-9]\.','C004' FROM dual UNION ALL
  SELECT 'Real Application Testing','Database Replay: Workload Replay','^11\.2|^1[289]\.|^2[0-9]\.','C004' FROM dual UNION ALL
  SELECT 'Real Application Testing','SQL Performance Analyzer','^11\.2|^1[289]\.|^2[0-9]\.','C004' FROM dual UNION ALL
  SELECT '.Secure Backup','Oracle Secure Backup','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Spatial and Graph','Spatial','^11\.2','INVALID' FROM dual UNION ALL
  SELECT 'Spatial and Graph','Spatial','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','Automatic Maintenance - SQL Tuning Advisor','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','Automatic SQL Tuning Advisor','^11\.2|^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','Real-Time SQL Monitoring','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','Real-Time SQL Monitoring','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Access Advisor','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Monitoring and Tuning pages','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Profile','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Tuning Advisor','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Tuning Set (user)','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','Tuning Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT '.WebLogic Server Management Pack Enterprise Edition','EM AS Provisioning and Patch Automation Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT '' product,'' feature,'' mversion,'' condition FROM dual
),
fus AS (
  SELECT
    CASE
      WHEN dbid||'#'||version||'#'||TO_CHAR(last_sample_date,'YYYYMMDDHH24MISS') =
           FIRST_VALUE(dbid)    OVER (ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)||'#'||
           FIRST_VALUE(version) OVER (ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)||'#'||
           FIRST_VALUE(TO_CHAR(last_sample_date,'YYYYMMDDHH24MISS'))
                                OVER (ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)
      THEN 'Y' ELSE 'N'
    END                 AS current_entry,
    name, last_sample_date, dbid, version,
    detected_usages, total_samples, currently_used,
    first_usage_date, last_usage_date, aux_count, feature_info
  FROM dba_feature_usage_statistics
),
pfus AS (
  SELECT
    product,
    name                AS feature_being_used,
    CASE
      WHEN condition = 'BUG'
           THEN '3.SUPPRESSED_DUE_TO_BUG'
      WHEN detected_usages > 0
           AND currently_used  = 'TRUE'
           AND current_entry   = 'Y'
           AND (TRIM(condition) IS NULL
                OR (condition_met = 'TRUE' AND condition_counter = 'FALSE'))
           THEN '6.CURRENT_USAGE'
      WHEN detected_usages > 0
           AND currently_used  = 'TRUE'
           AND current_entry   = 'Y'
           AND condition_met   = 'TRUE'
           AND condition_counter = 'TRUE'
           THEN '5.PAST_OR_CURRENT_USAGE'
      WHEN detected_usages > 0
           AND (TRIM(condition) IS NULL OR condition_met = 'TRUE')
           THEN '4.PAST_USAGE'
      WHEN current_entry = 'Y'
           THEN '2.NO_CURRENT_USAGE'
      ELSE '1.NO_PAST_USAGE'
    END                 AS usage,
    last_sample_date, version,
    detected_usages, total_samples, currently_used,
    CASE WHEN condition LIKE 'C___' AND condition_met = 'FALSE'
         THEN TO_DATE(NULL) ELSE first_usage_date END AS first_usage_date,
    CASE WHEN condition LIKE 'C___' AND condition_met = 'FALSE'
         THEN TO_DATE(NULL) ELSE last_usage_date  END AS last_usage_date
  FROM (
    SELECT
      m.product, m.condition,
      CASE
        WHEN m.condition = 'C001'
             AND (  (    REGEXP_LIKE(TO_CHAR(f.feature_info), 'compression[ -]used:[ 0-9]*[1-9][ 0-9]*time', 'i')
                     AND TO_CHAR(f.feature_info) NOT LIKE '%(BASIC algorithm used: 0 times, LOW algorithm used: 0 times, MEDIUM algorithm used: 0 times, HIGH algorithm used: 0 times)%')
                 OR REGEXP_LIKE(TO_CHAR(f.feature_info), 'compression[ -]used: *TRUE', 'i'))
             THEN 'TRUE'
        WHEN m.condition = 'C002'
             AND (REGEXP_LIKE(TO_CHAR(f.feature_info), 'encryption used:[ 0-9]*[1-9][ 0-9]*time', 'i')
               OR REGEXP_LIKE(TO_CHAR(f.feature_info), 'encryption used: *TRUE', 'i'))
             THEN 'TRUE'
        WHEN m.condition = 'C003' AND f.aux_count > 1 THEN 'TRUE'
        WHEN m.condition = 'C005' AND f.aux_count > 3 THEN 'TRUE'
        WHEN m.condition = 'C004'                      THEN 'TRUE'
        ELSE 'FALSE'
      END AS condition_met,
      CASE
        WHEN m.condition = 'C001'
             AND  REGEXP_LIKE(TO_CHAR(f.feature_info), 'compression[ -]used:[ 0-9]*[1-9][ 0-9]*time', 'i')
             AND  TO_CHAR(f.feature_info) NOT LIKE '%(BASIC algorithm used: 0 times, LOW algorithm used: 0 times, MEDIUM algorithm used: 0 times, HIGH algorithm used: 0 times)%'
             THEN 'TRUE'
        WHEN m.condition = 'C002'
             AND  REGEXP_LIKE(TO_CHAR(f.feature_info), 'encryption used:[ 0-9]*[1-9][ 0-9]*time', 'i')
             THEN 'TRUE'
        ELSE 'FALSE'
      END AS condition_counter,
      f.current_entry, f.name, f.last_sample_date, f.version,
      f.detected_usages, f.total_samples, f.currently_used,
      f.first_usage_date, f.last_usage_date, f.aux_count, f.feature_info
    FROM map m
    JOIN fus f ON m.feature = f.name AND REGEXP_LIKE(f.version, m.mversion)
    WHERE NVL(f.total_samples, 0) > 0
  )
  WHERE NVL(condition, '-') != 'INVALID'
)
SELECT
  '"'||REPLACE(product, '"', '""')||'"'        AS product,
  DECODE(MAX(usage),
    '2.NO_CURRENT_USAGE',      'NO_USAGE',
    '3.SUPPRESSED_DUE_TO_BUG', 'SUPPRESSED_DUE_TO_BUG',
    '4.PAST_USAGE',            'PAST_USAGE',
    '5.PAST_OR_CURRENT_USAGE', 'PAST_OR_CURRENT_USAGE',
    '6.CURRENT_USAGE',         'CURRENT_USAGE',
    'UNKNOWN')                                 AS usage_status,
  TO_CHAR(MIN(first_usage_date), 'YYYY-MM-DD') AS first_usage_date,
  TO_CHAR(MAX(last_usage_date),  'YYYY-MM-DD') AS last_usage_date,
  TO_CHAR(MAX(last_sample_date), 'YYYY-MM-DD') AS last_sample_date
FROM pfus
WHERE usage IN ('2.NO_CURRENT_USAGE', '4.PAST_USAGE',
                '5.PAST_OR_CURRENT_USAGE', '6.CURRENT_USAGE')
GROUP BY product
ORDER BY DECODE(SUBSTR(product,1,1), '.', 2, 1), product;

SPOOL OFF

-- =============================================================================
-- 4. FEATURE USAGE DETAIL — individual features mapped to licensed product
--    Cross-reference with product_usage.csv for the licence obligation summary.
--    INVALID features excluded; BUG-suppressed features included for visibility.
-- =============================================================================
SPOOL &sam_prefix._feature_usage.csv

PROMPT product,feature_name,usage_status,db_version,detected_usages,total_samples,currently_used,first_usage_date,last_usage_date

WITH
map AS (
  SELECT '' product,'' feature,'' mversion,'' condition FROM dual UNION ALL
  SELECT 'Active Data Guard','Active Data Guard - Real-Time Query on Physical Standby','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Active Data Guard','Global Data Services','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Active Data Guard or Real Application Clusters','Application Continuity','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Analytics','Data Mining','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','ADVANCED Index Compression','^12\.','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','Advanced Index Compression','^12\.','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','Advanced Index Compression','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup HIGH Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup LOW Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup MEDIUM Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup ZLIB Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Data Guard','^11\.2|^1[289]\.|^2[0-9]\.','C001' FROM dual UNION ALL
  SELECT 'Advanced Compression','Flashback Data Archive','^11\.2\.0\.[1-3]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Flashback Data Archive','^(11\.2\.0\.[4-9]\.|1[289]\.|2[0-9]\.)','INVALID' FROM dual UNION ALL
  SELECT 'Advanced Compression','HeapCompression','^11\.2|^12\.1','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','HeapCompression','^12\.[2-9]|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Heat Map','^12\.1','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','Heat Map','^12\.[2-9]|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Hybrid Columnar Compression Row Level Locking','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Information Lifecycle Management','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Oracle Advanced Network Compression Service','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Oracle Utility Datapump (Export)','^11\.2|^1[289]\.|^2[0-9]\.','C001' FROM dual UNION ALL
  SELECT 'Advanced Compression','Oracle Utility Datapump (Import)','^11\.2|^1[289]\.|^2[0-9]\.','C001' FROM dual UNION ALL
  SELECT 'Advanced Compression','SecureFile Compression (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','SecureFile Deduplication (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','ASO native encryption and checksumming','^11\.2|^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Advanced Security','Backup Encryption','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Backup Encryption','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Advanced Security','Data Redaction','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Encrypted Tablespaces','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Oracle Utility Datapump (Export)','^11\.2|^1[289]\.|^2[0-9]\.','C002' FROM dual UNION ALL
  SELECT 'Advanced Security','Oracle Utility Datapump (Import)','^11\.2|^1[289]\.|^2[0-9]\.','C002' FROM dual UNION ALL
  SELECT 'Advanced Security','SecureFile Encryption (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Transparent Data Encryption','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Change Management Pack','Change Management Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Configuration Management Pack for Oracle Database','EM Config Management Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Data Masking Pack','Data Masking Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT '.Database Gateway','Gateways','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Database Gateway','Transparent Gateway','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory ADO Policies','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Aggregation','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Column Store','^12\.1\.0\.2\.','BUG' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Column Store','^12\.1\.0\.[3-9]\.|^12\.2|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Distribute For Service (User Defined)','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Expressions','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory FastStart','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Join Groups','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database Vault','Oracle Database Vault','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database Vault','Privilege Capture','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','ADDM','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','AWR Baseline','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','AWR Baseline Template','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','AWR Report','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Automatic Workload Repository','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Baseline Adaptive Thresholds','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Baseline Static Computations','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Diagnostic Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','EM Performance Page','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Exadata','Cloud DB with EHCC','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Exadata','Exadata','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.GoldenGate','GoldenGate','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression','^12\.1','BUG' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression','^12\.[2-9]|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression Conventional Load','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression Row Level Locking','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','ODA Infrastructure','^1[9]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Sun ZFS with EHCC','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','ZFS Storage','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Zone maps','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Label Security','Label Security','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Multitenant','Oracle Multitenant','^1[28]\.','C003' FROM dual UNION ALL
  SELECT 'Multitenant','Oracle Multitenant','^1[9]\.|^2[0-9]\.','C005' FROM dual UNION ALL
  SELECT 'Multitenant','Oracle Pluggable Databases','^1[28]\.','C003' FROM dual UNION ALL
  SELECT 'OLAP','OLAP - Analytic Workspaces','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'OLAP','OLAP - Cubes','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Partitioning','Partitioning (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Partitioning','Zone maps','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Pillar Storage','Pillar Storage','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Pillar Storage','Pillar Storage with EHCC','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Provisioning and Patch Automation Pack','EM Standalone Provisioning and Patch Automation Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Provisioning and Patch Automation Pack for Database','EM Database Provisioning and Patch Automation Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'RAC or RAC One Node','Quality of Service Management','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Real Application Clusters','Real Application Clusters (RAC)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Real Application Clusters One Node','Real Application Cluster One Node','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Real Application Testing','Database Replay: Workload Capture','^11\.2|^1[289]\.|^2[0-9]\.','C004' FROM dual UNION ALL
  SELECT 'Real Application Testing','Database Replay: Workload Replay','^11\.2|^1[289]\.|^2[0-9]\.','C004' FROM dual UNION ALL
  SELECT 'Real Application Testing','SQL Performance Analyzer','^11\.2|^1[289]\.|^2[0-9]\.','C004' FROM dual UNION ALL
  SELECT '.Secure Backup','Oracle Secure Backup','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Spatial and Graph','Spatial','^11\.2','INVALID' FROM dual UNION ALL
  SELECT 'Spatial and Graph','Spatial','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','Automatic Maintenance - SQL Tuning Advisor','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','Automatic SQL Tuning Advisor','^11\.2|^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','Real-Time SQL Monitoring','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','Real-Time SQL Monitoring','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Access Advisor','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Monitoring and Tuning pages','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Profile','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Tuning Advisor','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Tuning Set (user)','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','Tuning Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT '.WebLogic Server Management Pack Enterprise Edition','EM AS Provisioning and Patch Automation Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT '' product,'' feature,'' mversion,'' condition FROM dual
),
fus AS (
  SELECT
    CASE
      WHEN dbid||'#'||version||'#'||TO_CHAR(last_sample_date,'YYYYMMDDHH24MISS') =
           FIRST_VALUE(dbid)    OVER (ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)||'#'||
           FIRST_VALUE(version) OVER (ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)||'#'||
           FIRST_VALUE(TO_CHAR(last_sample_date,'YYYYMMDDHH24MISS'))
                                OVER (ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)
      THEN 'Y' ELSE 'N'
    END                 AS current_entry,
    name, last_sample_date, dbid, version,
    detected_usages, total_samples, currently_used,
    first_usage_date, last_usage_date, aux_count, feature_info
  FROM dba_feature_usage_statistics
),
pfus AS (
  SELECT
    product,
    name                AS feature_being_used,
    CASE
      WHEN condition = 'BUG'
           THEN '3.SUPPRESSED_DUE_TO_BUG'
      WHEN detected_usages > 0
           AND currently_used  = 'TRUE'
           AND current_entry   = 'Y'
           AND (TRIM(condition) IS NULL
                OR (condition_met = 'TRUE' AND condition_counter = 'FALSE'))
           THEN '6.CURRENT_USAGE'
      WHEN detected_usages > 0
           AND currently_used  = 'TRUE'
           AND current_entry   = 'Y'
           AND condition_met   = 'TRUE'
           AND condition_counter = 'TRUE'
           THEN '5.PAST_OR_CURRENT_USAGE'
      WHEN detected_usages > 0
           AND (TRIM(condition) IS NULL OR condition_met = 'TRUE')
           THEN '4.PAST_USAGE'
      WHEN current_entry = 'Y'
           THEN '2.NO_CURRENT_USAGE'
      ELSE '1.NO_PAST_USAGE'
    END                 AS usage,
    last_sample_date, version,
    detected_usages, total_samples, currently_used,
    CASE WHEN condition LIKE 'C___' AND condition_met = 'FALSE'
         THEN TO_DATE(NULL) ELSE first_usage_date END AS first_usage_date,
    CASE WHEN condition LIKE 'C___' AND condition_met = 'FALSE'
         THEN TO_DATE(NULL) ELSE last_usage_date  END AS last_usage_date
  FROM (
    SELECT
      m.product, m.condition,
      CASE
        WHEN m.condition = 'C001'
             AND (  (    REGEXP_LIKE(TO_CHAR(f.feature_info), 'compression[ -]used:[ 0-9]*[1-9][ 0-9]*time', 'i')
                     AND TO_CHAR(f.feature_info) NOT LIKE '%(BASIC algorithm used: 0 times, LOW algorithm used: 0 times, MEDIUM algorithm used: 0 times, HIGH algorithm used: 0 times)%')
                 OR REGEXP_LIKE(TO_CHAR(f.feature_info), 'compression[ -]used: *TRUE', 'i'))
             THEN 'TRUE'
        WHEN m.condition = 'C002'
             AND (REGEXP_LIKE(TO_CHAR(f.feature_info), 'encryption used:[ 0-9]*[1-9][ 0-9]*time', 'i')
               OR REGEXP_LIKE(TO_CHAR(f.feature_info), 'encryption used: *TRUE', 'i'))
             THEN 'TRUE'
        WHEN m.condition = 'C003' AND f.aux_count > 1 THEN 'TRUE'
        WHEN m.condition = 'C005' AND f.aux_count > 3 THEN 'TRUE'
        WHEN m.condition = 'C004'                      THEN 'TRUE'
        ELSE 'FALSE'
      END AS condition_met,
      CASE
        WHEN m.condition = 'C001'
             AND  REGEXP_LIKE(TO_CHAR(f.feature_info), 'compression[ -]used:[ 0-9]*[1-9][ 0-9]*time', 'i')
             AND  TO_CHAR(f.feature_info) NOT LIKE '%(BASIC algorithm used: 0 times, LOW algorithm used: 0 times, MEDIUM algorithm used: 0 times, HIGH algorithm used: 0 times)%'
             THEN 'TRUE'
        WHEN m.condition = 'C002'
             AND  REGEXP_LIKE(TO_CHAR(f.feature_info), 'encryption used:[ 0-9]*[1-9][ 0-9]*time', 'i')
             THEN 'TRUE'
        ELSE 'FALSE'
      END AS condition_counter,
      f.current_entry, f.name, f.last_sample_date, f.version,
      f.detected_usages, f.total_samples, f.currently_used,
      f.first_usage_date, f.last_usage_date, f.aux_count, f.feature_info
    FROM map m
    JOIN fus f ON m.feature = f.name AND REGEXP_LIKE(f.version, m.mversion)
    WHERE NVL(f.total_samples, 0) > 0
  )
  WHERE NVL(condition, '-') != 'INVALID'
)
SELECT
  '"'||REPLACE(product,           '"', '""')||'"' AS product,
  '"'||REPLACE(feature_being_used,'"', '""')||'"' AS feature_name,
  DECODE(usage,
    '2.NO_CURRENT_USAGE',      'NO_CURRENT_USAGE',
    '3.SUPPRESSED_DUE_TO_BUG', 'SUPPRESSED_DUE_TO_BUG',
    '4.PAST_USAGE',            'PAST_USAGE',
    '5.PAST_OR_CURRENT_USAGE', 'PAST_OR_CURRENT_USAGE',
    '6.CURRENT_USAGE',         'CURRENT_USAGE',
    'UNKNOWN')                                     AS usage_status,
  SUBSTR(version, 1, 20)                           AS db_version,
  NVL(detected_usages, 0)                          AS detected_usages,
  NVL(total_samples, 0)                            AS total_samples,
  currently_used,
  TO_CHAR(first_usage_date, 'YYYY-MM-DD')          AS first_usage_date,
  TO_CHAR(last_usage_date,  'YYYY-MM-DD')          AS last_usage_date
FROM pfus
WHERE usage IN ('2.NO_CURRENT_USAGE', '3.SUPPRESSED_DUE_TO_BUG',
                '4.PAST_USAGE', '5.PAST_OR_CURRENT_USAGE', '6.CURRENT_USAGE')
ORDER BY DECODE(SUBSTR(product,1,1), '.', 2, 1), product, feature_being_used;

SPOOL OFF

-- =============================================================================
-- 5. NAMED USER PLUS counts
-- =============================================================================
SPOOL &sam_prefix._users.csv

PROMPT category,user_count

SELECT 'Total non-Oracle users' AS category, COUNT(*) AS user_count FROM dba_users WHERE oracle_maintained = 'N'
UNION ALL
SELECT 'Active (OPEN)',  COUNT(*) FROM dba_users WHERE oracle_maintained = 'N' AND account_status = 'OPEN'
UNION ALL
SELECT 'Locked',         COUNT(*) FROM dba_users WHERE oracle_maintained = 'N' AND account_status LIKE '%LOCKED%'
UNION ALL
SELECT 'Expired',        COUNT(*) FROM dba_users WHERE oracle_maintained = 'N' AND account_status LIKE '%EXPIRED%';

SPOOL OFF

-- =============================================================================
-- 6. PDBs (only populated for CDB databases) — topology only
-- =============================================================================
SPOOL &sam_prefix._pdbs.csv

PROMPT pdb_name,con_id,open_mode,restricted

SELECT
  p.name                  AS pdb_name,
  p.con_id,
  p.open_mode,
  NVL(p.restricted, 'NO') AS restricted
FROM   v$pdbs p
WHERE  p.con_id > 0
ORDER  BY p.con_id;

SPOOL OFF

-- =============================================================================
-- 7. PDB FEATURE USAGE — per-PDB licensed features from CDB_FEATURE_USAGE_STATISTICS
--    Only populated for CDB databases (connect to CDB$ROOT).
--    Applies full MOS Doc ID 1317265.1 MAP logic partitioned by con_id so that
--    only the most-recent DBID/VERSION sample per PDB is used (CURRENT_ENTRY).
--    INVALID features excluded; BUG-suppressed features included for visibility.
--    C003/C005 (Multitenant) excluded at PDB level (con_id > 1) per Oracle guidance.
-- =============================================================================
SPOOL &sam_prefix._pdb_feature_usage.csv

PROMPT pdb_name,con_id,product,feature_name,usage_status,db_version,detected_usages,total_samples,currently_used,first_usage_date,last_usage_date

-- Disable substitution-variable processing so no & inside SQL strings or
-- comments triggers a SQL*Plus prompt during this complex query.
SET DEFINE OFF

WITH
map AS (
  SELECT '' product,'' feature,'' mversion,'' condition FROM dual UNION ALL
  SELECT 'Active Data Guard','Active Data Guard - Real-Time Query on Physical Standby','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Active Data Guard','Global Data Services','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Active Data Guard or Real Application Clusters','Application Continuity','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Analytics','Data Mining','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','ADVANCED Index Compression','^12\.','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','Advanced Index Compression','^12\.','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','Advanced Index Compression','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup HIGH Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup LOW Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup MEDIUM Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Backup ZLIB Compression','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Data Guard','^11\.2|^1[289]\.|^2[0-9]\.','C001' FROM dual UNION ALL
  SELECT 'Advanced Compression','Flashback Data Archive','^11\.2\.0\.[1-3]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Flashback Data Archive','^(11\.2\.0\.[4-9]\.|1[289]\.|2[0-9]\.)','INVALID' FROM dual UNION ALL
  SELECT 'Advanced Compression','HeapCompression','^11\.2|^12\.1','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','HeapCompression','^12\.[2-9]|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Heat Map','^12\.1','BUG' FROM dual UNION ALL
  SELECT 'Advanced Compression','Heat Map','^12\.[2-9]|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Hybrid Columnar Compression Row Level Locking','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Information Lifecycle Management','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Oracle Advanced Network Compression Service','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','Oracle Utility Datapump (Export)','^11\.2|^1[289]\.|^2[0-9]\.','C001' FROM dual UNION ALL
  SELECT 'Advanced Compression','Oracle Utility Datapump (Import)','^11\.2|^1[289]\.|^2[0-9]\.','C001' FROM dual UNION ALL
  SELECT 'Advanced Compression','SecureFile Compression (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Compression','SecureFile Deduplication (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','ASO native encryption and checksumming','^11\.2|^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Advanced Security','Backup Encryption','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Backup Encryption','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Advanced Security','Data Redaction','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Encrypted Tablespaces','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Oracle Utility Datapump (Export)','^11\.2|^1[289]\.|^2[0-9]\.','C002' FROM dual UNION ALL
  SELECT 'Advanced Security','Oracle Utility Datapump (Import)','^11\.2|^1[289]\.|^2[0-9]\.','C002' FROM dual UNION ALL
  SELECT 'Advanced Security','SecureFile Encryption (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Advanced Security','Transparent Data Encryption','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Change Management Pack','Change Management Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Configuration Management Pack for Oracle Database','EM Config Management Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Data Masking Pack','Data Masking Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT '.Database Gateway','Gateways','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Database Gateway','Transparent Gateway','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory ADO Policies','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Aggregation','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Column Store','^12\.1\.0\.2\.','BUG' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Column Store','^12\.1\.0\.[3-9]\.|^12\.2|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Distribute For Service (User Defined)','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Expressions','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory FastStart','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database In-Memory','In-Memory Join Groups','^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database Vault','Oracle Database Vault','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Database Vault','Privilege Capture','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','ADDM','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','AWR Baseline','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','AWR Baseline Template','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','AWR Report','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Automatic Workload Repository','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Baseline Adaptive Thresholds','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Baseline Static Computations','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','Diagnostic Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Diagnostics Pack','EM Performance Page','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Exadata','Cloud DB with EHCC','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Exadata','Exadata','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.GoldenGate','GoldenGate','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression','^12\.1','BUG' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression','^12\.[2-9]|^1[89]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression Conventional Load','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Hybrid Columnar Compression Row Level Locking','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','ODA Infrastructure','^1[9]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Sun ZFS with EHCC','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','ZFS Storage','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.HW','Zone maps','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Label Security','Label Security','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Multitenant','Oracle Multitenant','^1[28]\.','C003' FROM dual UNION ALL
  SELECT 'Multitenant','Oracle Multitenant','^1[9]\.|^2[0-9]\.','C005' FROM dual UNION ALL
  SELECT 'Multitenant','Oracle Pluggable Databases','^1[28]\.','C003' FROM dual UNION ALL
  SELECT 'OLAP','OLAP - Analytic Workspaces','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'OLAP','OLAP - Cubes','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Partitioning','Partitioning (user)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Partitioning','Zone maps','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Pillar Storage','Pillar Storage','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Pillar Storage','Pillar Storage with EHCC','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT '.Provisioning and Patch Automation Pack','EM Standalone Provisioning and Patch Automation Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Provisioning and Patch Automation Pack for Database','EM Database Provisioning and Patch Automation Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'RAC or RAC One Node','Quality of Service Management','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Real Application Clusters','Real Application Clusters (RAC)','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Real Application Clusters One Node','Real Application Cluster One Node','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Real Application Testing','Database Replay: Workload Capture','^11\.2|^1[289]\.|^2[0-9]\.','C004' FROM dual UNION ALL
  SELECT 'Real Application Testing','Database Replay: Workload Replay','^11\.2|^1[289]\.|^2[0-9]\.','C004' FROM dual UNION ALL
  SELECT 'Real Application Testing','SQL Performance Analyzer','^11\.2|^1[289]\.|^2[0-9]\.','C004' FROM dual UNION ALL
  SELECT '.Secure Backup','Oracle Secure Backup','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Spatial and Graph','Spatial','^11\.2','INVALID' FROM dual UNION ALL
  SELECT 'Spatial and Graph','Spatial','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','Automatic Maintenance - SQL Tuning Advisor','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','Automatic SQL Tuning Advisor','^11\.2|^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','Real-Time SQL Monitoring','^11\.2', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','Real-Time SQL Monitoring','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Access Advisor','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Monitoring and Tuning pages','^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Profile','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Tuning Advisor','^11\.2|^1[289]\.|^2[0-9]\.', ' ' FROM dual UNION ALL
  SELECT 'Tuning Pack','SQL Tuning Set (user)','^1[289]\.|^2[0-9]\.','INVALID' FROM dual UNION ALL
  SELECT 'Tuning Pack','Tuning Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT '.WebLogic Server Management Pack Enterprise Edition','EM AS Provisioning and Patch Automation Pack','^11\.2', ' ' FROM dual UNION ALL
  SELECT '' product,'' feature,'' mversion,'' condition FROM dual
),
-- CDB_FEATURE_USAGE_STATISTICS deduplicated to most-recent sample per con_id.
-- FIRST_VALUE partitioned by con_id gives each PDB its own CURRENT_ENTRY,
-- matching the per-container deduplication in MOS Doc ID 1317265.1.
fus AS (
  SELECT
    con_id,
    CASE
      WHEN dbid||'#'||version||'#'||TO_CHAR(last_sample_date,'YYYYMMDDHH24MISS') =
           FIRST_VALUE(dbid)    OVER (PARTITION BY con_id ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)||'#'||
           FIRST_VALUE(version) OVER (PARTITION BY con_id ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)||'#'||
           FIRST_VALUE(TO_CHAR(last_sample_date,'YYYYMMDDHH24MISS'))
                                OVER (PARTITION BY con_id ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)
      THEN 'Y' ELSE 'N'
    END                 AS current_entry,
    name, last_sample_date, dbid, version,
    detected_usages, total_samples, currently_used,
    first_usage_date, last_usage_date, aux_count, feature_info
  FROM cdb_feature_usage_statistics
  WHERE con_id > 1
),
pfus AS (
  SELECT
    con_id,
    product,
    name                AS feature_being_used,
    CASE
      WHEN condition = 'BUG'
           THEN '3.SUPPRESSED_DUE_TO_BUG'
      WHEN detected_usages > 0
           AND currently_used  = 'TRUE'
           AND current_entry   = 'Y'
           AND (TRIM(condition) IS NULL
                OR (condition_met = 'TRUE' AND condition_counter = 'FALSE'))
           THEN '6.CURRENT_USAGE'
      WHEN detected_usages > 0
           AND currently_used  = 'TRUE'
           AND current_entry   = 'Y'
           AND condition_met   = 'TRUE'
           AND condition_counter = 'TRUE'
           THEN '5.PAST_OR_CURRENT_USAGE'
      WHEN detected_usages > 0
           AND (TRIM(condition) IS NULL OR condition_met = 'TRUE')
           THEN '4.PAST_USAGE'
      WHEN current_entry = 'Y'
           THEN '2.NO_CURRENT_USAGE'
      ELSE '1.NO_PAST_USAGE'
    END                 AS usage,
    last_sample_date, version,
    detected_usages, total_samples, currently_used,
    CASE WHEN condition LIKE 'C___' AND condition_met = 'FALSE'
         THEN TO_DATE(NULL) ELSE first_usage_date END AS first_usage_date,
    CASE WHEN condition LIKE 'C___' AND condition_met = 'FALSE'
         THEN TO_DATE(NULL) ELSE last_usage_date  END AS last_usage_date
  FROM (
    SELECT
      f.con_id,
      m.product, m.condition,
      CASE
        WHEN m.condition = 'C001'
             AND (  (    REGEXP_LIKE(TO_CHAR(f.feature_info), 'compression[ -]used:[ 0-9]*[1-9][ 0-9]*time', 'i')
                     AND TO_CHAR(f.feature_info) NOT LIKE '%(BASIC algorithm used: 0 times, LOW algorithm used: 0 times, MEDIUM algorithm used: 0 times, HIGH algorithm used: 0 times)%')
                 OR REGEXP_LIKE(TO_CHAR(f.feature_info), 'compression[ -]used: *TRUE', 'i'))
             THEN 'TRUE'
        WHEN m.condition = 'C002'
             AND (REGEXP_LIKE(TO_CHAR(f.feature_info), 'encryption used:[ 0-9]*[1-9][ 0-9]*time', 'i')
               OR REGEXP_LIKE(TO_CHAR(f.feature_info), 'encryption used: *TRUE', 'i'))
             THEN 'TRUE'
        WHEN m.condition = 'C003' AND f.aux_count > 1 THEN 'TRUE'
        WHEN m.condition = 'C005' AND f.aux_count > 3 THEN 'TRUE'
        WHEN m.condition = 'C004'                      THEN 'TRUE'
        ELSE 'FALSE'
      END AS condition_met,
      CASE
        WHEN m.condition = 'C001'
             AND  REGEXP_LIKE(TO_CHAR(f.feature_info), 'compression[ -]used:[ 0-9]*[1-9][ 0-9]*time', 'i')
             AND  TO_CHAR(f.feature_info) NOT LIKE '%(BASIC algorithm used: 0 times, LOW algorithm used: 0 times, MEDIUM algorithm used: 0 times, HIGH algorithm used: 0 times)%'
             THEN 'TRUE'
        WHEN m.condition = 'C002'
             AND  REGEXP_LIKE(TO_CHAR(f.feature_info), 'encryption used:[ 0-9]*[1-9][ 0-9]*time', 'i')
             THEN 'TRUE'
        ELSE 'FALSE'
      END AS condition_counter,
      f.current_entry, f.name, f.last_sample_date, f.version,
      f.detected_usages, f.total_samples, f.currently_used,
      f.first_usage_date, f.last_usage_date
    FROM map m
    JOIN fus f ON m.feature = f.name AND REGEXP_LIKE(f.version, m.mversion)
    WHERE NVL(f.total_samples, 0) > 0
      AND NOT (m.condition IN ('C003','C005'))
  ) inner_pfus
  WHERE NVL(condition, '-') != 'INVALID'
)
SELECT
  p.name                                                               AS pdb_name,
  pf.con_id,
  '"'||REPLACE(pf.product,           '"', '""')||'"'                  AS product,
  '"'||REPLACE(pf.feature_being_used,'"', '""')||'"'                  AS feature_name,
  DECODE(pf.usage,
    '2.NO_CURRENT_USAGE',      'NO_CURRENT_USAGE',
    '3.SUPPRESSED_DUE_TO_BUG', 'SUPPRESSED_DUE_TO_BUG',
    '4.PAST_USAGE',            'PAST_USAGE',
    '5.PAST_OR_CURRENT_USAGE', 'PAST_OR_CURRENT_USAGE',
    '6.CURRENT_USAGE',         'CURRENT_USAGE',
    'UNKNOWN')                                                         AS usage_status,
  SUBSTR(pf.version, 1, 20)                                           AS db_version,
  NVL(pf.detected_usages, 0)                                          AS detected_usages,
  NVL(pf.total_samples, 0)                                            AS total_samples,
  pf.currently_used,
  TO_CHAR(pf.first_usage_date, 'YYYY-MM-DD')                         AS first_usage_date,
  TO_CHAR(pf.last_usage_date,  'YYYY-MM-DD')                         AS last_usage_date
FROM pfus pf
JOIN v$pdbs p ON p.con_id = pf.con_id
WHERE pf.usage IN ('2.NO_CURRENT_USAGE', '3.SUPPRESSED_DUE_TO_BUG',
                   '4.PAST_USAGE', '5.PAST_OR_CURRENT_USAGE', '6.CURRENT_USAGE')
ORDER BY p.name, DECODE(SUBSTR(pf.product,1,1), '.', 2, 1), pf.product, pf.feature_being_used;

SPOOL OFF
SET DEFINE ON

-- =============================================================================
-- 8. MANAGEMENT PACK PARAMETERS — GV$PARAMETER per container
--    control_management_pack_access:
--      NONE                  — no Diagnostics or Tuning Pack licensed
--      DIAGNOSTIC            — Diagnostics Pack only
--      DIAGNOSTIC+TUNING     — both Diagnostics and Tuning Pack licensed
-- =============================================================================
SPOOL &sam_prefix._mgmt_packs.csv

PROMPT con_id,container_type,param_name,param_value,diagnostics_licensed,tuning_licensed

WITH params AS (
  SELECT
    con_id,
    LOWER(name)            AS param_name,
    UPPER(SUBSTR(value,1,64)) AS param_value
  FROM   gv$parameter
  WHERE  LOWER(name) IN ('control_management_pack_access', 'enable_ddl_logging')
    AND  inst_id = 1
  ORDER  BY con_id, param_name
)
SELECT
  p.con_id,
  CASE WHEN p.con_id IN (0, 1) THEN 'CDB' ELSE 'PDB' END     AS container_type,
  p.param_name,
  p.param_value,
  CASE WHEN p.param_name = 'control_management_pack_access'
            AND p.param_value IN ('DIAGNOSTIC', 'DIAGNOSTIC+TUNING')
       THEN 'YES' ELSE 'NO' END                                AS diagnostics_licensed,
  CASE WHEN p.param_name = 'control_management_pack_access'
            AND p.param_value = 'DIAGNOSTIC+TUNING'
       THEN 'YES' ELSE 'NO' END                                AS tuning_licensed
FROM params p
ORDER BY p.con_id, p.param_name;

SPOOL OFF

-- =============================================================================
-- 9. RAC nodes (only populated for RAC databases)
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
PROMPT    &sam_prefix._product_usage.csv        (PRIMARY - licence by product)
PROMPT    &sam_prefix._feature_usage.csv        (CDB-level detail with product mapping)
PROMPT    &sam_prefix._pdb_feature_usage.csv    (per-PDB feature detail; CDB only)
PROMPT    &sam_prefix._users.csv
PROMPT    &sam_prefix._pdbs.csv                 (CDB only; topology)
PROMPT    &sam_prefix._mgmt_packs.csv           (GV$PARAMETER pack settings per container)
PROMPT    &sam_prefix._rac_nodes.csv            (RAC only)
PROMPT
PROMPT  MAP logic: MOS Doc ID 1317265.1 (Oct-2021 v21.0)
PROMPT ============================================================

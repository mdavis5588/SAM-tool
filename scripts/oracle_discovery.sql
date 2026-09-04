-- =============================================================================
-- Oracle SAM Discovery Script
-- Run with SQL*Plus directly on the Oracle DB server when Ansible is unavailable.
--
-- Usage:
--   sqlplus / as sysdba @oracle_discovery.sql
--   sqlplus sam_discovery/<password>@<tns_alias> @oracle_discovery.sql
--
-- Output: oracle_discovery_<hostname>_<db_unique_name>_<timestamp>.json
--   Feed this file to scripts/load_discovery.py to import into the SAM database.
--   Or use run_and_load.sh to run discovery and load in one step.
--
-- Feature usage is collected from DBA_FEATURE_USAGE_STATISTICS (not v$option)
-- because it records actual detected usage counts, first/last used dates, and
-- current usage state — the same data Oracle auditors examine.
--
-- Management-pack licensing (Diagnostics/Tuning Pack) is collected from
-- GV$PARAMETER (control_management_pack_access) at both CDB and PDB level.
-- PDB entries include NUP user counts and per-PDB pack access.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET TRIMSPOOL ON
SET LINESIZE 32767
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET ECHO OFF
SET VERIFY OFF
SET TERMOUT OFF

-- sam_cpu_model / sam_cpu_arch must be DEFINE'd before running this file,
-- either by run_discovery.sh (recommended) or manually:
--   DEFINE sam_cpu_model = 'Intel Xeon Silver 4214'
--   DEFINE sam_cpu_arch  = 'x86_64'
-- The PL/SQL body falls back to v$parameter when the value is 'unknown'.

-- Derive output filename: oracle_discovery_<host>_<db_unique_name>_<timestamp>.json
COLUMN sam_outfile NEW_VALUE sam_outfile NOPRINT
SELECT 'oracle_discovery_'
       || LOWER(REPLACE(i.host_name, '.', '_'))
       || '_'
       || LOWER(d.db_unique_name)
       || '_'
       || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS')
       || '.json'  AS sam_outfile
FROM   v$instance i
CROSS  JOIN v$database d;

SPOOL &sam_outfile

-- =============================================================================
-- Main discovery block
-- =============================================================================
DECLARE
  -- Server / OS
  v_hostname         VARCHAR2(256);
  v_fqdn             VARCHAR2(256);
  v_ip               VARCHAR2(64);
  v_os_family        VARCHAR2(100);
  v_os_dist          VARCHAR2(200);
  v_os_ver           VARCHAR2(200);
  v_platform         VARCHAR2(200);

  -- CPU / hardware
  v_cpu_model        VARCHAR2(256);
  v_cpu_arch         VARCHAR2(64);
  v_cpu_sockets      NUMBER := 0;
  v_cores_per_sock   NUMBER := 0;
  v_threads_per_core NUMBER := 1;
  v_vcpu_count       NUMBER := 0;
  v_is_vmware        VARCHAR2(5) := 'false';
  v_virt_type        VARCHAR2(64) := 'physical';
  v_is_exadata       VARCHAR2(5) := 'false';
  v_ram_mb           NUMBER := 0;

  -- Run metadata
  v_run_id           VARCHAR2(64);
  v_datacenter       VARCHAR2(200) := '';
  v_environment      VARCHAR2(64)  := 'production';

  -- Edition (resolved in loop body to avoid bulk-bind truncation)
  v_edition          VARCHAR2(100);

  -- JSON assembly
  v_instances_json   CLOB := '';
  v_inst_sep         VARCHAR2(1) := '';
  v_features_json    CLOB := '';
  v_feat_sep         VARCHAR2(1) := '';
  v_params_json      CLOB := '';
  v_param_sep        VARCHAR2(1) := '';

  -- Management-pack access parameters (from GV$PARAMETER)
  v_db_unique_name   VARCHAR2(64)  := '';
  v_mgmt_pack_access VARCHAR2(64)  := 'NONE';
  v_ddl_logging      VARCHAR2(10)  := 'FALSE';
  v_diag_licensed    VARCHAR2(5)   := 'false';
  v_tuning_licensed  VARCHAR2(5)   := 'false';

  -- Per-PDB feature variables
  v_pdb_feat_json    CLOB          := '';
  v_pdb_feat_sep     VARCHAR2(1)   := '';

  -- Cursors
  CURSOR c_instances IS
    SELECT i.instance_number,
           i.instance_name,
           d.name                          AS db_name,
           d.db_unique_name,
           d.cdb,
           d.log_mode,
           SUBSTR(i.version, 1, 20)        AS db_version,
           SUBSTR(d.platform_name, 1, 100) AS platform_name
    FROM   v$instance i
    CROSS  JOIN v$database d;

  CURSOR c_rac_nodes IS
    SELECT inst_id, instance_name, host_name
    FROM   gv$instance
    ORDER  BY inst_id;

  CURSOR c_pdbs IS
    SELECT p.name    AS pdb_name,
           p.con_id,
           p.open_mode,
           p.restricted
    FROM   v$pdbs p
    WHERE  p.con_id > 0;

  -- DBA_FEATURE_USAGE_STATISTICS replaces v$option.
  -- Only rows where DETECTED_USAGES > 0 represent features Oracle has actually
  -- seen in use — these are the ones that matter for licence compliance.
  -- We include CURRENTLY_USED = FALSE rows too so auditors can see what was
  -- used historically but may have been turned off.
  -- Features marked INVALID in MOS Doc ID 1317265.1 MAP CTE are excluded —
  -- these are system-triggered or false-positive entries that do not indicate
  -- customer licence use.
  CURSOR c_features IS
    SELECT SUBSTR(name, 1, 200)              AS feature_name,
           SUBSTR(version, 1, 20)            AS db_version,
           NVL(detected_usages, 0)           AS detected_usages,
           NVL(total_samples, 0)             AS total_samples,
           CASE WHEN currently_used = 'TRUE' THEN 'true' ELSE 'false' END
                                             AS currently_used,
           TO_CHAR(first_usage_date, 'YYYY-MM-DD') AS first_usage_date,
           TO_CHAR(last_usage_date,  'YYYY-MM-DD') AS last_usage_date,
           SUBSTR(NVL(description, ''), 1, 500) AS description
    FROM   dba_feature_usage_statistics
    WHERE  detected_usages > 0
      AND  name NOT IN (
               'ASO native encryption and checksumming',
               'Automatic Maintenance - SQL Tuning Advisor',
               'Automatic Maintenance - Space Advisor',
               'Automatic Segment Advisor',
               'Automatic SQL Tuning Advisor',
               'EM Performance Page',
               'File Mapping',
               'Label Security',
               'OLAP - Analytic Workspaces',
               'Oracle Secure Backup',
               'Real-Time SQL Monitoring',
               'SQL Access Advisor',
               'SQL Tuning Advisor',
               'SQL Tuning Set (user)',
               'Segment Advisor'
           )
    ORDER  BY name;

  v_inst_rec      c_instances%ROWTYPE;
  v_node_rec      c_rac_nodes%ROWTYPE;
  v_pdb_rec       c_pdbs%ROWTYPE;
  v_feat_rec      c_features%ROWTYPE;
  v_nup_active    NUMBER := 0;
  v_nup_total     NUMBER := 0;
  v_nup_locked    NUMBER := 0;
  v_rac_node_sep  VARCHAR2(1) := '';
  v_pdb_sep       VARCHAR2(1) := '';
  v_rac_nodes_json CLOB := '';
  v_pdbs_json     CLOB := '';
  v_is_rac        BOOLEAN := FALSE;
  v_is_cdb        BOOLEAN := FALSE;
  v_node_count    NUMBER := 0;
  v_pdb_count     NUMBER := 0;
  v_cdb_flag      VARCHAR2(3);

  -- JSON string escaper
  FUNCTION j(p IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN REPLACE(REPLACE(REPLACE(NVL(p,''), '\', '\\'), '"', '\"'), CHR(10), '\n');
  END;

BEGIN
  v_run_id := 'manual-' || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS');

  -- --------------------------------------------------------
  -- Hostname / OS
  -- --------------------------------------------------------
  BEGIN
    SELECT LOWER(host_name), version
    INTO   v_hostname, v_os_dist
    FROM   v$instance;
  EXCEPTION WHEN OTHERS THEN v_hostname := 'unknown'; v_os_dist := '';
  END;
  BEGIN
    SELECT LOWER(db_unique_name) INTO v_db_unique_name FROM v$database;
  EXCEPTION WHEN OTHERS THEN v_db_unique_name := 'unknown';
  END;

  v_fqdn := v_hostname;

  BEGIN
    SELECT LOWER(platform_name) INTO v_platform FROM v$database;
    IF    v_platform LIKE '%linux%'   THEN v_os_family := 'linux';
    ELSIF v_platform LIKE '%windows%' THEN v_os_family := 'windows';
    ELSIF v_platform LIKE '%solaris%' THEN v_os_family := 'solaris';
    ELSIF v_platform LIKE '%aix%'     THEN v_os_family := 'aix';
    ELSIF v_platform LIKE '%hp%'      THEN v_os_family := 'hpux';
    ELSE                                   v_os_family := 'unknown';
    END IF;
    v_os_ver := v_platform;
  EXCEPTION WHEN OTHERS THEN v_os_family := 'unknown';
  END;

  -- --------------------------------------------------------
  -- CPU / hardware
  -- --------------------------------------------------------
  BEGIN SELECT value INTO v_cpu_sockets     FROM v$osstat WHERE stat_name = 'NUM_CPU_SOCKETS';     EXCEPTION WHEN OTHERS THEN v_cpu_sockets := 1; END;
  DECLARE v_total_cores NUMBER := 0;
  BEGIN
    SELECT value INTO v_cores_per_sock FROM v$osstat WHERE stat_name = 'NUM_CORES_PER_SOCKET';
  EXCEPTION WHEN OTHERS THEN
    -- Derive from total cores / sockets when the per-socket stat is unavailable
    BEGIN
      SELECT value INTO v_total_cores FROM v$osstat WHERE stat_name = 'NUM_CPU_CORES';
      v_cores_per_sock := GREATEST(1, ROUND(v_total_cores / GREATEST(1, v_cpu_sockets)));
    EXCEPTION WHEN OTHERS THEN v_cores_per_sock := 1;
    END;
  END;
  DECLARE v_total_cores2 NUMBER := 0;
  BEGIN
    SELECT value INTO v_threads_per_core FROM v$osstat WHERE stat_name = 'NUM_THREADS_PER_CORE';
  EXCEPTION WHEN OTHERS THEN
    -- Derive from vcpu_count / total_cores when the per-core stat is unavailable
    BEGIN
      SELECT value INTO v_total_cores2 FROM v$osstat WHERE stat_name = 'NUM_CPU_CORES';
      v_threads_per_core := GREATEST(1, ROUND(v_vcpu_count / GREATEST(1, v_total_cores2)));
    EXCEPTION WHEN OTHERS THEN v_threads_per_core := 1;
    END;
  END;
  BEGIN SELECT value INTO v_vcpu_count      FROM v$osstat WHERE stat_name = 'NUM_CPUS';             EXCEPTION WHEN OTHERS THEN v_vcpu_count := v_cpu_sockets * v_cores_per_sock; END;
  BEGIN
    SELECT value / 1024 / 1024 INTO v_ram_mb FROM v$osstat WHERE stat_name = 'PHYSICAL_MEMORY_BYTES';
  EXCEPTION WHEN OTHERS THEN v_ram_mb := 0;
  END;
  -- Use OS-supplied values from the shell wrapper if available; fall back to
  -- v$parameter (rarely populated) and finally the DEFINE defaults.
  v_cpu_model := NULLIF(TRIM('&sam_cpu_model'), 'unknown');
  v_cpu_arch  := NULLIF(TRIM('&sam_cpu_arch'),  'x86_64');
  IF v_cpu_model IS NULL THEN
    BEGIN SELECT SUBSTR(value,1,256)       INTO v_cpu_model FROM v$parameter WHERE name = 'processor_type' AND value IS NOT NULL; EXCEPTION WHEN OTHERS THEN NULL; END;
    v_cpu_model := NVL(v_cpu_model, 'unknown');
  END IF;
  IF v_cpu_arch IS NULL THEN
    BEGIN SELECT SUBSTR(LOWER(value),1,64) INTO v_cpu_arch  FROM v$parameter WHERE name = 'cpu_type' AND value IS NOT NULL; EXCEPTION WHEN OTHERS THEN NULL; END;
    v_cpu_arch := NVL(v_cpu_arch, 'x86_64');
  END IF;

  -- --------------------------------------------------------
  -- RAC check
  -- --------------------------------------------------------
  BEGIN SELECT COUNT(*) INTO v_node_count FROM gv$instance; EXCEPTION WHEN OTHERS THEN v_node_count := 1; END;
  v_is_rac := (v_node_count > 1);

  -- --------------------------------------------------------
  -- Exadata detection
  -- --------------------------------------------------------
  BEGIN
    -- gv$cell has rows only when Exadata storage cells are present
    DECLARE v_cell_cnt NUMBER := 0;
    BEGIN
      EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM gv$cell' INTO v_cell_cnt;
      IF v_cell_cnt > 0 THEN v_is_exadata := 'true'; END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END;
  IF v_is_exadata = 'false' THEN
    -- cell_offload_processing = TRUE is set by Exadata initialisation
    BEGIN
      DECLARE v_cop VARCHAR2(10);
      BEGIN
        SELECT UPPER(value) INTO v_cop FROM v$parameter WHERE name = 'cell_offload_processing';
        IF v_cop = 'TRUE' THEN v_is_exadata := 'true'; END IF;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END;
  END IF;

  -- --------------------------------------------------------
  -- Instances
  -- --------------------------------------------------------
  FOR v_inst_rec IN c_instances LOOP

    -- Edition from v$version (safe SUBSTR, outside cursor to avoid ORA-06502)
    v_edition := 'Unknown';
    BEGIN
      SELECT SUBSTR(CASE
               WHEN UPPER(banner) LIKE '%ENTERPRISE%'       THEN 'Enterprise Edition'
               WHEN UPPER(banner) LIKE '%STANDARD EDITION 2%' THEN 'Standard Edition 2'
               WHEN UPPER(banner) LIKE '%STANDARD%'         THEN 'Standard Edition'
               WHEN UPPER(banner) LIKE '%EXPRESS%'          THEN 'Express Edition'
               ELSE banner END, 1, 100)
      INTO v_edition
      FROM v$version
      WHERE UPPER(banner) LIKE '%ORACLE DATABASE%'
      AND   ROWNUM = 1;
    EXCEPTION WHEN OTHERS THEN v_edition := 'Unknown';
    END;

    v_cdb_flag := v_inst_rec.cdb;
    v_is_cdb   := (v_cdb_flag = 'YES');

    -- RAC nodes
    v_rac_nodes_json := ''; v_rac_node_sep := '';
    IF v_is_rac THEN
      FOR v_node_rec IN c_rac_nodes LOOP
        v_rac_nodes_json := v_rac_nodes_json || v_rac_node_sep
          || '{"node_name":"'     || j(LOWER(v_node_rec.host_name))
          || '","node_number":'   || v_node_rec.inst_id
          || ',"instance_name":"' || j(v_node_rec.instance_name) || '"}';
        v_rac_node_sep := ',';
      END LOOP;
    END IF;

    -- PDBs (with per-PDB feature usage from cdb_feature_usage_statistics)
    v_pdbs_json := ''; v_pdb_sep := ''; v_pdb_count := 0;
    IF v_is_cdb THEN
      FOR v_pdb_rec IN c_pdbs LOOP
        -- Per-PDB feature usage (requires CDB$ROOT connection; gracefully skipped if unavailable)
        v_pdb_feat_json := ''; v_pdb_feat_sep := '';
        BEGIN
          FOR v_feat_rec IN (
            -- Deduplicate to most-recent DBID/VERSION sample (CURRENT_ENTRY = 'Y')
            -- to match the MAP/CURRENT_ENTRY logic used in oracle_discovery_csv.sql.
            SELECT feature_name, db_version, detected_usages, total_samples,
                   currently_used, first_usage_date, last_usage_date, description
            FROM (
              SELECT SUBSTR(name, 1, 200)              AS feature_name,
                     SUBSTR(version, 1, 20)            AS db_version,
                     NVL(detected_usages, 0)           AS detected_usages,
                     NVL(total_samples, 0)             AS total_samples,
                     CASE WHEN currently_used = 'TRUE' THEN 'true' ELSE 'false' END AS currently_used,
                     TO_CHAR(first_usage_date, 'YYYY-MM-DD') AS first_usage_date,
                     TO_CHAR(last_usage_date,  'YYYY-MM-DD') AS last_usage_date,
                     SUBSTR(NVL(description, ''), 1, 500)    AS description,
                     CASE
                       WHEN dbid||'#'||version||'#'||TO_CHAR(last_sample_date,'YYYYMMDDHH24MISS') =
                            FIRST_VALUE(dbid)    OVER (ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)||'#'||
                            FIRST_VALUE(version) OVER (ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)||'#'||
                            FIRST_VALUE(TO_CHAR(last_sample_date,'YYYYMMDDHH24MISS'))
                                                 OVER (ORDER BY last_sample_date DESC NULLS LAST, dbid DESC)
                       THEN 'Y' ELSE 'N'
                     END AS current_entry
              FROM   cdb_feature_usage_statistics
              WHERE  con_id = v_pdb_rec.con_id
                AND  name NOT IN (
                         'ASO native encryption and checksumming',
                         'Automatic Maintenance - SQL Tuning Advisor',
                         'Automatic Maintenance - Space Advisor',
                         'Automatic Segment Advisor',
                         'Automatic SQL Tuning Advisor',
                         'EM Performance Page',
                         'File Mapping',
                         'Label Security',
                         'OLAP - Analytic Workspaces',
                         'Oracle Secure Backup',
                         'Real-Time SQL Monitoring',
                         'SQL Access Advisor',
                         'SQL Tuning Advisor',
                         'SQL Tuning Set (user)',
                         'Segment Advisor'
                     )
            )
            WHERE  current_entry = 'Y'
              AND  detected_usages > 0
            ORDER BY feature_name
          ) LOOP
            v_pdb_feat_json := v_pdb_feat_json || v_pdb_feat_sep
              || '{"feature_name":"'    || j(v_feat_rec.feature_name)
              || '","db_version":"'     || j(v_feat_rec.db_version)
              || '","detected_usages":' || v_feat_rec.detected_usages
              || ',"total_samples":'    || v_feat_rec.total_samples
              || ',"currently_used":'   || v_feat_rec.currently_used
              || ',"first_usage_date":' || CASE WHEN v_feat_rec.first_usage_date IS NOT NULL
                                                THEN '"' || v_feat_rec.first_usage_date || '"'
                                                ELSE 'null' END
              || ',"last_usage_date":'  || CASE WHEN v_feat_rec.last_usage_date IS NOT NULL
                                                THEN '"' || v_feat_rec.last_usage_date || '"'
                                                ELSE 'null' END
              || ',"description":"'     || j(v_feat_rec.description) || '"}';
            v_pdb_feat_sep := ',';
          END LOOP;
        EXCEPTION WHEN OTHERS THEN NULL;  -- cdb_feature_usage_statistics not accessible; skip
        END;

        v_pdbs_json := v_pdbs_json || v_pdb_sep
          || '{"pdb_name":"'    || j(v_pdb_rec.pdb_name)
          || '","con_id":'      || v_pdb_rec.con_id
          || ',"open_mode":"'   || j(v_pdb_rec.open_mode)
          || '","restricted":"' || j(NVL(v_pdb_rec.restricted,'NO'))
          || '","feature_usage":[' || v_pdb_feat_json || ']}';
        v_pdb_sep := ','; v_pdb_count := v_pdb_count + 1;
      END LOOP;
    END IF;

    -- NUP counts
    v_nup_active := 0; v_nup_total := 0; v_nup_locked := 0;
    BEGIN
      SELECT COUNT(*) INTO v_nup_active FROM dba_users WHERE account_status = 'OPEN'  AND oracle_maintained = 'N';
      SELECT COUNT(*) INTO v_nup_total  FROM dba_users WHERE oracle_maintained = 'N';
      SELECT COUNT(*) INTO v_nup_locked FROM dba_users WHERE account_status != 'OPEN' AND oracle_maintained = 'N';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    v_instances_json := v_instances_json || v_inst_sep
      || '{"sid":"'             || j(v_inst_rec.instance_name)
      || '","db_name":"'        || j(v_inst_rec.db_name)
      || '","edition":"'        || j(v_edition)
      || '","version":"'        || j(v_inst_rec.db_version)
      || '","platform_name":"'  || j(v_inst_rec.platform_name)
      || '","is_cdb":'          || CASE WHEN v_is_cdb THEN 'true' ELSE 'false' END
      || ',"is_rac":'           || CASE WHEN v_is_rac THEN 'true' ELSE 'false' END
      || ',"rac_nodes":['       || v_rac_nodes_json || ']'
      || ',"pdbs":['            || v_pdbs_json || ']'
      || ',"nup_active_users":' || v_nup_active
      || ',"nup_total_users":'  || v_nup_total
      || ',"nup_locked_users":' || v_nup_locked
      || ',"nup_sample_users":[]'
      || '}';
    v_inst_sep := ',';
  END LOOP;

  -- --------------------------------------------------------
  -- Feature usage (DBA_FEATURE_USAGE_STATISTICS)
  -- --------------------------------------------------------
  FOR v_feat_rec IN c_features LOOP
    v_features_json := v_features_json || v_feat_sep
      || '{"feature_name":"'    || j(v_feat_rec.feature_name)
      || '","db_version":"'     || j(v_feat_rec.db_version)
      || '","detected_usages":' || v_feat_rec.detected_usages
      || ',"total_samples":'    || v_feat_rec.total_samples
      || ',"currently_used":'   || v_feat_rec.currently_used
      || ',"first_usage_date":' || CASE WHEN v_feat_rec.first_usage_date IS NOT NULL
                                        THEN '"' || v_feat_rec.first_usage_date || '"'
                                        ELSE 'null' END
      || ',"last_usage_date":'  || CASE WHEN v_feat_rec.last_usage_date IS NOT NULL
                                        THEN '"' || v_feat_rec.last_usage_date || '"'
                                        ELSE 'null' END
      || ',"description":"'     || j(v_feat_rec.description) || '"}';
    v_feat_sep := ',';
  END LOOP;

  -- --------------------------------------------------------
  -- Management-pack access: GV$PARAMETER (RAC-aware, inst_id=1)
  -- control_management_pack_access:
  --   NONE              = no packs licensed
  --   DIAGNOSTIC        = Diagnostics Pack licensed
  --   DIAGNOSTIC+TUNING = both packs licensed
  -- --------------------------------------------------------
  BEGIN
    SELECT UPPER(SUBSTR(value,1,64)) INTO v_mgmt_pack_access
    FROM gv$parameter WHERE LOWER(name)='control_management_pack_access' AND inst_id=1 AND con_id IN (0,1) AND ROWNUM=1;
  EXCEPTION WHEN OTHERS THEN v_mgmt_pack_access := 'NONE';
  END;
  BEGIN
    SELECT UPPER(SUBSTR(value,1,10)) INTO v_ddl_logging
    FROM gv$parameter WHERE LOWER(name)='enable_ddl_logging' AND inst_id=1 AND con_id IN (0,1) AND ROWNUM=1;
  EXCEPTION WHEN OTHERS THEN v_ddl_logging := 'FALSE';
  END;

  v_diag_licensed   := CASE WHEN v_mgmt_pack_access IN ('DIAGNOSTIC','DIAGNOSTIC+TUNING') THEN 'true' ELSE 'false' END;
  v_tuning_licensed := CASE WHEN v_mgmt_pack_access = 'DIAGNOSTIC+TUNING' THEN 'true' ELSE 'false' END;

  -- Raw parameter array — one entry per container (con_id=1 CDB$ROOT, >1 PDB override)
  FOR v_p IN (
    SELECT DISTINCT con_id, LOWER(name) AS pname, SUBSTR(value,1,256) AS pvalue
    FROM   gv$parameter
    WHERE  LOWER(name) IN ('control_management_pack_access','enable_ddl_logging')
      AND  inst_id = 1
    ORDER  BY con_id, pname
  ) LOOP
    v_params_json := v_params_json || v_param_sep
      || '{"con_id":'  || v_p.con_id
      || ',"name":"'   || j(v_p.pname)
      || '","value":"' || j(v_p.pvalue) || '"}';
    v_param_sep := ',';
  END LOOP;

  -- --------------------------------------------------------
  -- Emit JSON
  -- --------------------------------------------------------
  DBMS_OUTPUT.PUT_LINE('{');
  DBMS_OUTPUT.PUT_LINE('"_meta":{"script_version":"2.1","generated":"' || TO_CHAR(SYSDATE,'YYYY-MM-DD"T"HH24:MI:SS') || '","hostname":"' || j(v_hostname) || '","db_unique_name":"' || j(v_db_unique_name) || '"},');

  DBMS_OUTPUT.PUT_LINE('"base":{');
  DBMS_OUTPUT.PUT_LINE('  "run_id":"'               || v_run_id          || '",');
  DBMS_OUTPUT.PUT_LINE('  "hostname":"'             || j(v_hostname)     || '",');
  DBMS_OUTPUT.PUT_LINE('  "fqdn":"'                 || j(v_fqdn)         || '",');
  DBMS_OUTPUT.PUT_LINE('  "ip_address":null,');
  DBMS_OUTPUT.PUT_LINE('  "os_family":"'            || j(v_os_family)    || '",');
  DBMS_OUTPUT.PUT_LINE('  "os_distribution":"'      || j(v_os_dist)      || '",');
  DBMS_OUTPUT.PUT_LINE('  "os_version":"'           || j(v_os_ver)       || '",');
  DBMS_OUTPUT.PUT_LINE('  "environment":"'          || j(v_environment)  || '",');
  DBMS_OUTPUT.PUT_LINE('  "criticality":"medium",');
  DBMS_OUTPUT.PUT_LINE('  "datacenter":"'           || j(v_datacenter)   || '",');
  DBMS_OUTPUT.PUT_LINE('  "total_ram_mb":'          || v_ram_mb          || ',');
  DBMS_OUTPUT.PUT_LINE('  "cpu_model":"'            || j(v_cpu_model)    || '",');
  DBMS_OUTPUT.PUT_LINE('  "cpu_architecture":"'     || j(v_cpu_arch)     || '",');
  DBMS_OUTPUT.PUT_LINE('  "cpu_sockets":'           || v_cpu_sockets     || ',');
  DBMS_OUTPUT.PUT_LINE('  "cpu_cores_per_socket":'  || v_cores_per_sock  || ',');
  DBMS_OUTPUT.PUT_LINE('  "cpu_threads_per_core":'  || v_threads_per_core || ',');
  DBMS_OUTPUT.PUT_LINE('  "vcpu_count":'            || v_vcpu_count      || ',');
  DBMS_OUTPUT.PUT_LINE('  "virt_type":"'            || j(v_virt_type)    || '",');
  DBMS_OUTPUT.PUT_LINE('  "is_vmware":'             || v_is_vmware       || ',');
  DBMS_OUTPUT.PUT_LINE('  "is_exadata":'            || v_is_exadata      || ',');
  DBMS_OUTPUT.PUT_LINE('  "instances":['            || v_instances_json  || ']');
  DBMS_OUTPUT.PUT_LINE('},');

  DBMS_OUTPUT.PUT_LINE('"extended":{');
  DBMS_OUTPUT.PUT_LINE('  "run_id":"'    || v_run_id     || '",');
  DBMS_OUTPUT.PUT_LINE('  "hostname":"'  || j(v_hostname) || '",');
  DBMS_OUTPUT.PUT_LINE('  "instances":[' || v_instances_json || ']');
  DBMS_OUTPUT.PUT_LINE('},');

  -- Feature usage (DBA_FEATURE_USAGE_STATISTICS)
  DBMS_OUTPUT.PUT_LINE('"feature_usage":['  || v_features_json || '],');

  -- Management-pack access (CDB level + per-PDB overrides where set)
  DBMS_OUTPUT.PUT_LINE('"mgmt_pack_summary":{');
  DBMS_OUTPUT.PUT_LINE('  "control_management_pack_access":"' || j(v_mgmt_pack_access) || '",');
  DBMS_OUTPUT.PUT_LINE('  "diagnostics_licensed":' || v_diag_licensed   || ',');
  DBMS_OUTPUT.PUT_LINE('  "tuning_licensed":'      || v_tuning_licensed || ',');
  DBMS_OUTPUT.PUT_LINE('  "ddl_logging":'          || CASE WHEN v_ddl_logging = 'TRUE' THEN 'true' ELSE 'false' END);
  DBMS_OUTPUT.PUT_LINE('},');

  -- Raw per-container parameter values for the loader
  DBMS_OUTPUT.PUT_LINE('"db_parameters":['  || v_params_json   || ']');
  DBMS_OUTPUT.PUT_LINE('}');

EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('{"error":"' || SQLERRM || '"}');
END;
/

SPOOL OFF
SET TERMOUT ON
SET FEEDBACK ON

PROMPT
PROMPT ============================================================
PROMPT  Discovery complete (JSON).
PROMPT  Output file: &sam_outfile
PROMPT  Next step  : python3 scripts/load_discovery.py &sam_outfile
PROMPT ============================================================

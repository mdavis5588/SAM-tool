-- =============================================================================
-- Oracle SAM Discovery Script
-- Run with SQL*Plus directly on the Oracle DB server when Ansible is unavailable.
--
-- Usage:
--   sqlplus / as sysdba @oracle_discovery.sql
--   sqlplus sys/<password>@<tns_alias> as sysdba @oracle_discovery.sql
--
-- Output: oracle_discovery_<hostname>_<date>.json
--   Feed this file to scripts/load_discovery.py to import into the SAM database.
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

-- Derive output filename from hostname + date
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
-- Main discovery block — outputs a single JSON document
-- =============================================================================
DECLARE
  -- Server / OS
  v_hostname        VARCHAR2(256);
  v_fqdn            VARCHAR2(256);
  v_ip              VARCHAR2(64);
  v_os_family       VARCHAR2(100);
  v_os_dist         VARCHAR2(200);
  v_os_ver          VARCHAR2(200);
  v_platform        VARCHAR2(200);

  -- CPU / hardware
  v_cpu_model       VARCHAR2(256);
  v_cpu_arch        VARCHAR2(64);
  v_cpu_sockets     NUMBER := 0;
  v_cores_per_sock  NUMBER := 0;
  v_threads_per_core NUMBER := 1;
  v_vcpu_count      NUMBER := 0;
  v_is_vmware       VARCHAR2(5) := 'false';
  v_virt_type       VARCHAR2(64) := 'physical';
  v_ram_mb          NUMBER := 0;

  -- Run metadata
  v_run_id          VARCHAR2(64);
  v_datacenter      VARCHAR2(200) := '';
  v_environment     VARCHAR2(64)  := 'production';

  -- JSON assembly
  v_instances_json  CLOB := '';
  v_inst_sep        VARCHAR2(1) := '';
  v_ext_json        CLOB := '';
  v_ext_inst_sep    VARCHAR2(1) := '';
  v_options_json    CLOB := '';
  v_opt_sep         VARCHAR2(1) := '';
  v_params_json     CLOB := '';
  v_param_sep       VARCHAR2(1) := '';

  -- Management-pack access parameters (from GV$PARAMETER)
  v_mgmt_pack_access  VARCHAR2(64)  := 'NONE';
  v_ddl_logging       VARCHAR2(10)  := 'FALSE';
  v_diag_licensed     VARCHAR2(5)   := 'false';
  v_tuning_licensed   VARCHAR2(5)   := 'false';

  -- Edition resolved separately in loop body to avoid bulk-bind truncation
  -- (v$version.banner width varies by Oracle release)
  v_edition         VARCHAR2(100);

  -- Cursors
  -- Note: edition is NOT selected here — it is derived in the loop body
  -- via v$version to avoid ORA-06502 bulk-bind truncation on wide banner columns.
  CURSOR c_instances IS
    SELECT i.instance_number,
           i.instance_name,
           d.name                        AS db_name,
           d.db_unique_name,
           d.cdb,
           d.log_mode,
           SUBSTR(i.version, 1, 20)      AS db_version,
           SUBSTR(d.platform_name, 1, 100) AS platform_name  -- on v$database, not v$instance
    FROM   v$instance i
    CROSS  JOIN v$database d;

  CURSOR c_rac_nodes IS
    SELECT inst_id, instance_name, host_name
    FROM   gv$instance
    ORDER  BY inst_id;

  CURSOR c_pdbs IS
    SELECT p.name      AS pdb_name,
           p.con_id,
           p.open_mode,
           p.restricted
    FROM   v$pdbs p
    WHERE  p.con_id > 0;

  CURSOR c_nup_users (p_con_id NUMBER) IS
    SELECT COUNT(*) AS active_count
    FROM   dba_users
    WHERE  account_status = 'OPEN'
      AND  oracle_maintained = 'N';

  CURSOR c_options IS
    SELECT parameter AS option_name,
           value     AS is_active
    FROM   v$option
    ORDER  BY parameter;

  v_inst_rec       c_instances%ROWTYPE;
  v_node_rec       c_rac_nodes%ROWTYPE;
  v_pdb_rec        c_pdbs%ROWTYPE;
  v_nup_active     NUMBER := 0;
  v_nup_total      NUMBER := 0;
  v_nup_locked     NUMBER := 0;
  v_pdb_nup_active NUMBER := 0;
  v_pdb_nup_total  NUMBER := 0;
  v_pdb_mgmt_pack  VARCHAR2(64)  := '';
  v_pdb_ddl_log    VARCHAR2(10)  := '';
  v_rac_node_sep   VARCHAR2(1) := '';
  v_pdb_sep        VARCHAR2(1) := '';
  v_rac_nodes_json CLOB := '';
  v_pdbs_json      CLOB := '';
  v_is_rac         BOOLEAN := FALSE;
  v_is_cdb         BOOLEAN := FALSE;
  v_node_count     NUMBER := 0;
  v_pdb_count      NUMBER := 0;
  v_cdb_flag       VARCHAR2(3);
  v_db_unique_name VARCHAR2(64)  := '';

  -- Escape helper
  FUNCTION j(p IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN REPLACE(REPLACE(REPLACE(p, '\', '\\'), '"', '\"'), CHR(10), '\n');
  END;

BEGIN
  -- --------------------------------------------------------
  -- Run ID
  -- --------------------------------------------------------
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

  v_fqdn   := v_hostname;   -- Fallback — update if DNS FQDN is known

  -- Attempt to identify OS from platform_name
  BEGIN
    SELECT LOWER(platform_name) INTO v_platform FROM v$database;
    IF v_platform LIKE '%linux%' THEN
      v_os_family := 'linux';
    ELSIF v_platform LIKE '%windows%' THEN
      v_os_family := 'windows';
    ELSIF v_platform LIKE '%solaris%' THEN
      v_os_family := 'solaris';
    ELSIF v_platform LIKE '%aix%' THEN
      v_os_family := 'aix';
    ELSIF v_platform LIKE '%hp%' THEN
      v_os_family := 'hpux';
    ELSE
      v_os_family := 'unknown';
    END IF;
    v_os_ver := v_platform;
  EXCEPTION WHEN OTHERS THEN v_os_family := 'unknown';
  END;

  -- --------------------------------------------------------
  -- CPU / hardware from v$osstat
  -- --------------------------------------------------------
  BEGIN
    SELECT value INTO v_cpu_sockets FROM v$osstat WHERE stat_name = 'NUM_CPU_SOCKETS';
  EXCEPTION WHEN OTHERS THEN v_cpu_sockets := 1;
  END;
  BEGIN
    SELECT value INTO v_cores_per_sock FROM v$osstat WHERE stat_name = 'NUM_CORES_PER_SOCKET';
  EXCEPTION WHEN OTHERS THEN v_cores_per_sock := 1;
  END;
  BEGIN
    SELECT value INTO v_threads_per_core FROM v$osstat WHERE stat_name = 'NUM_THREADS_PER_CORE';
  EXCEPTION WHEN OTHERS THEN v_threads_per_core := 1;
  END;
  BEGIN
    SELECT value INTO v_vcpu_count FROM v$osstat WHERE stat_name = 'NUM_CPUS';
  EXCEPTION WHEN OTHERS THEN v_vcpu_count := v_cpu_sockets * v_cores_per_sock;
  END;
  BEGIN
    SELECT value * 1024 INTO v_ram_mb FROM v$osstat WHERE stat_name = 'PHYSICAL_MEMORY_BYTES';
    v_ram_mb := v_ram_mb / 1024 / 1024;  -- bytes -> MB
  EXCEPTION WHEN OTHERS THEN v_ram_mb := 0;
  END;

  -- CPU model from v$parameter (best effort; SUBSTR guards against wide value columns)
  BEGIN
    SELECT SUBSTR(value, 1, 256) INTO v_cpu_model FROM v$parameter WHERE name = 'processor_type';
  EXCEPTION WHEN OTHERS THEN v_cpu_model := 'unknown';
  END;

  -- Architecture / virtualisation flags
  BEGIN
    SELECT SUBSTR(LOWER(value), 1, 64) INTO v_cpu_arch FROM v$parameter WHERE name = 'cpu_type';
  EXCEPTION WHEN OTHERS THEN v_cpu_arch := 'x86_64';
  END;

  -- Check for VM/Virtualisation via DBA_REGISTRY_SQLPATCH or v$option
  BEGIN
    SELECT 'true', 'vmware'
    INTO   v_is_vmware, v_virt_type
    FROM   dual
    WHERE  EXISTS (
      SELECT 1 FROM v$option
      WHERE  parameter = 'Oracle Database Vault'
        AND  LOWER(value) = 'true'
    )
    AND    ROWNUM = 1;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- --------------------------------------------------------
  -- Check RAC
  -- --------------------------------------------------------
  SELECT COUNT(*) INTO v_node_count FROM gv$instance;
  v_is_rac := (v_node_count > 1);

  -- --------------------------------------------------------
  -- Build instances JSON array
  -- --------------------------------------------------------
  FOR v_inst_rec IN c_instances LOOP
    -- Derive edition safely — v$version.banner width varies by release,
    -- so we read it here with SUBSTR rather than inside the cursor SELECT.
    v_edition := 'Unknown';
    BEGIN
      SELECT SUBSTR(
               CASE
                 WHEN UPPER(banner) LIKE '%ENTERPRISE%' THEN 'Enterprise Edition'
                 WHEN UPPER(banner) LIKE '%STANDARD EDITION 2%' THEN 'Standard Edition 2'
                 WHEN UPPER(banner) LIKE '%STANDARD%' THEN 'Standard Edition'
                 WHEN UPPER(banner) LIKE '%EXPRESS%' THEN 'Express Edition'
                 ELSE banner
               END, 1, 100)
      INTO v_edition
      FROM v$version
      WHERE UPPER(banner) LIKE '%ORACLE DATABASE%'
      AND   ROWNUM = 1;
    EXCEPTION WHEN OTHERS THEN v_edition := 'Unknown';
    END;

    -- Check CDB
    v_cdb_flag := v_inst_rec.cdb;
    v_is_cdb   := (v_cdb_flag = 'YES');

    -- RAC nodes for this instance
    v_rac_nodes_json := '';
    v_rac_node_sep   := '';
    IF v_is_rac THEN
      FOR v_node_rec IN c_rac_nodes LOOP
        v_rac_nodes_json := v_rac_nodes_json || v_rac_node_sep
          || '{"node_name":"' || j(LOWER(v_node_rec.host_name))
          || '","node_number":' || v_node_rec.inst_id
          || ',"instance_name":"' || j(v_node_rec.instance_name)
          || '"}';
        v_rac_node_sep := ',';
      END LOOP;
    END IF;

    -- PDBs for CDB
    v_pdbs_json  := '';
    v_pdb_sep    := '';
    v_pdb_count  := 0;
    IF v_is_cdb THEN
      FOR v_pdb_rec IN c_pdbs LOOP
        -- NUP user counts per PDB via CDB_USERS (requires CDB$ROOT connection)
        v_pdb_nup_active := 0;
        v_pdb_nup_total  := 0;
        BEGIN
          SELECT COUNT(*) INTO v_pdb_nup_active
          FROM   cdb_users
          WHERE  oracle_maintained = 'N'
            AND  account_status    = 'OPEN'
            AND  con_id            = v_pdb_rec.con_id;
          SELECT COUNT(*) INTO v_pdb_nup_total
          FROM   cdb_users
          WHERE  oracle_maintained = 'N'
            AND  con_id            = v_pdb_rec.con_id;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        -- Management-pack parameter for this PDB (may differ from CDB if PDB overrides it)
        v_pdb_mgmt_pack := v_mgmt_pack_access;  -- default: inherit CDB value
        v_pdb_ddl_log   := v_ddl_logging;
        BEGIN
          SELECT UPPER(SUBSTR(value, 1, 64))
          INTO   v_pdb_mgmt_pack
          FROM   gv$parameter
          WHERE  LOWER(name) = 'control_management_pack_access'
            AND  inst_id     = 1
            AND  con_id      = v_pdb_rec.con_id;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        BEGIN
          SELECT UPPER(SUBSTR(value, 1, 10))
          INTO   v_pdb_ddl_log
          FROM   gv$parameter
          WHERE  LOWER(name) = 'enable_ddl_logging'
            AND  inst_id     = 1
            AND  con_id      = v_pdb_rec.con_id;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        v_pdbs_json := v_pdbs_json || v_pdb_sep
          || '{"pdb_name":"'              || j(v_pdb_rec.pdb_name)
          || '","con_id":'                || v_pdb_rec.con_id
          || ',"open_mode":"'             || j(v_pdb_rec.open_mode)
          || '","restricted":"'           || j(NVL(v_pdb_rec.restricted,'NO'))
          || '","nup_active_users":'      || v_pdb_nup_active
          || ',"nup_total_users":'        || v_pdb_nup_total
          || ',"mgmt_pack_access":"'      || j(v_pdb_mgmt_pack)
          || '","diagnostics_licensed":'  || CASE WHEN v_pdb_mgmt_pack IN ('DIAGNOSTIC','DIAGNOSTIC+TUNING') THEN 'true' ELSE 'false' END
          || ',"tuning_licensed":'        || CASE WHEN v_pdb_mgmt_pack = 'DIAGNOSTIC+TUNING' THEN 'true' ELSE 'false' END
          || ',"ddl_logging":'            || CASE WHEN v_pdb_ddl_log = 'TRUE' THEN 'true' ELSE 'false' END
          || '}';
        v_pdb_sep   := ',';
        v_pdb_count := v_pdb_count + 1;
      END LOOP;
    END IF;

    -- NUP user counts
    v_nup_active  := 0;
    v_nup_total   := 0;
    v_nup_locked  := 0;
    BEGIN
      SELECT COUNT(*) INTO v_nup_active FROM dba_users
      WHERE account_status = 'OPEN' AND oracle_maintained = 'N';
      SELECT COUNT(*) INTO v_nup_total  FROM dba_users
      WHERE oracle_maintained = 'N';
      SELECT COUNT(*) INTO v_nup_locked FROM dba_users
      WHERE account_status != 'OPEN' AND oracle_maintained = 'N';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    v_instances_json := v_instances_json || v_inst_sep
      || '{"sid":"'           || j(v_inst_rec.instance_name)
      || '","db_name":"'      || j(v_inst_rec.db_name)
      || '","edition":"'      || j(v_edition)
      || '","version":"'      || j(v_inst_rec.db_version)
      || '","platform_name":"'|| j(v_inst_rec.platform_name)
      || '","is_cdb":'        || CASE WHEN v_is_cdb THEN 'true' ELSE 'false' END
      || ',"is_rac":'         || CASE WHEN v_is_rac THEN 'true' ELSE 'false' END
      || ',"rac_nodes":['     || v_rac_nodes_json || ']'
      || ',"pdbs":['          || v_pdbs_json || ']'
      || ',"nup_active_users":' || v_nup_active
      || ',"nup_total_users":' || v_nup_total
      || ',"nup_locked_users":' || v_nup_locked
      || ',"nup_sample_users":[]'
      || '}';
    v_inst_sep := ',';
  END LOOP;

  -- --------------------------------------------------------
  -- Management-pack access: GV$PARAMETER (RAC-aware, node 1 wins)
  -- control_management_pack_access values:
  --   NONE              = no packs licensed
  --   DIAGNOSTIC        = Diagnostics Pack licensed
  --   DIAGNOSTIC+TUNING = both packs licensed
  -- --------------------------------------------------------
  BEGIN
    SELECT UPPER(SUBSTR(value, 1, 64))
    INTO   v_mgmt_pack_access
    FROM   gv$parameter
    WHERE  LOWER(name) = 'control_management_pack_access'
      AND  inst_id = 1;
  EXCEPTION WHEN OTHERS THEN v_mgmt_pack_access := 'NONE';
  END;
  BEGIN
    SELECT UPPER(SUBSTR(value, 1, 10))
    INTO   v_ddl_logging
    FROM   gv$parameter
    WHERE  LOWER(name) = 'enable_ddl_logging'
      AND  inst_id = 1;
  EXCEPTION WHEN OTHERS THEN v_ddl_logging := 'FALSE';
  END;

  v_diag_licensed    := CASE WHEN v_mgmt_pack_access IN ('DIAGNOSTIC','DIAGNOSTIC+TUNING')
                             THEN 'true' ELSE 'false' END;
  v_tuning_licensed  := CASE WHEN v_mgmt_pack_access = 'DIAGNOSTIC+TUNING'
                             THEN 'true' ELSE 'false' END;

  -- Raw parameter array — one entry per container (con_id=1 is CDB$ROOT, >1 are PDBs)
  -- con_id=0 means the value is inherited across all containers (no PDB override set)
  FOR v_p IN (
    SELECT DISTINCT con_id, LOWER(name) AS pname, SUBSTR(value, 1, 256) AS pvalue
    FROM   gv$parameter
    WHERE  LOWER(name) IN ('control_management_pack_access', 'enable_ddl_logging')
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
  -- Build options JSON array (v$option flags + synthesized pack entries)
  -- --------------------------------------------------------
  FOR v_opt_rec IN (
    SELECT parameter AS option_name, value AS is_active
    FROM   v$option ORDER BY parameter
  ) LOOP
    v_options_json := v_options_json || v_opt_sep
      || '{"option_name":"' || j(v_opt_rec.option_name)
      || '","is_active":'   || CASE WHEN LOWER(v_opt_rec.is_active) = 'true' THEN 'true' ELSE 'false' END
      || '}';
    v_opt_sep := ',';
  END LOOP;

  -- Synthesized management-pack entries derived from control_management_pack_access
  v_options_json := v_options_json || v_opt_sep
    || '{"option_name":"Diagnostics Pack","is_active":' || v_diag_licensed   || '}';
  v_opt_sep := ',';
  v_options_json := v_options_json || v_opt_sep
    || '{"option_name":"Tuning Pack","is_active":'      || v_tuning_licensed || '}';
  v_options_json := v_options_json || v_opt_sep
    || '{"option_name":"DDL Logging","is_active":'
    || CASE WHEN v_ddl_logging = 'TRUE' THEN 'true' ELSE 'false' END || '}';

  -- --------------------------------------------------------
  -- Emit final JSON document
  -- Two top-level keys: "base" and "extended" — the loader
  -- calls upsert_oracle_discovery and then
  -- upsert_oracle_extended_discovery with the same hostname.
  -- --------------------------------------------------------
  DBMS_OUTPUT.PUT_LINE('{');
  DBMS_OUTPUT.PUT_LINE('"_meta":{"script_version":"1.1","generated":"' || TO_CHAR(SYSDATE,'YYYY-MM-DD"T"HH24:MI:SS') || '","hostname":"' || j(v_hostname) || '","db_unique_name":"' || j(v_db_unique_name) || '"},');

  -- BASE payload
  DBMS_OUTPUT.PUT_LINE('"base":{');
  DBMS_OUTPUT.PUT_LINE('  "run_id":"'          || v_run_id || '",');
  DBMS_OUTPUT.PUT_LINE('  "hostname":"'        || j(v_hostname)     || '",');
  DBMS_OUTPUT.PUT_LINE('  "fqdn":"'            || j(v_fqdn)         || '",');
  DBMS_OUTPUT.PUT_LINE('  "ip_address":null,');
  DBMS_OUTPUT.PUT_LINE('  "os_family":"'       || j(v_os_family)    || '",');
  DBMS_OUTPUT.PUT_LINE('  "os_distribution":"' || j(v_os_dist)      || '",');
  DBMS_OUTPUT.PUT_LINE('  "os_version":"'      || j(v_os_ver)       || '",');
  DBMS_OUTPUT.PUT_LINE('  "environment":"'     || j(v_environment)  || '",');
  DBMS_OUTPUT.PUT_LINE('  "criticality":"medium",');
  DBMS_OUTPUT.PUT_LINE('  "datacenter":"'      || j(v_datacenter)   || '",');
  DBMS_OUTPUT.PUT_LINE('  "total_ram_mb":'     || v_ram_mb          || ',');
  DBMS_OUTPUT.PUT_LINE('  "cpu_model":"'       || j(v_cpu_model)    || '",');
  DBMS_OUTPUT.PUT_LINE('  "cpu_architecture":"'|| j(v_cpu_arch)     || '",');
  DBMS_OUTPUT.PUT_LINE('  "cpu_sockets":'      || v_cpu_sockets     || ',');
  DBMS_OUTPUT.PUT_LINE('  "cpu_cores_per_socket":' || v_cores_per_sock || ',');
  DBMS_OUTPUT.PUT_LINE('  "cpu_threads_per_core":' || v_threads_per_core || ',');
  DBMS_OUTPUT.PUT_LINE('  "vcpu_count":'       || v_vcpu_count      || ',');
  DBMS_OUTPUT.PUT_LINE('  "virt_type":"'       || j(v_virt_type)    || '",');
  DBMS_OUTPUT.PUT_LINE('  "is_vmware":'        || v_is_vmware       || ',');
  DBMS_OUTPUT.PUT_LINE('  "instances":['       || v_instances_json  || ']');
  DBMS_OUTPUT.PUT_LINE('},');

  -- EXTENDED payload (RAC nodes, PDBs, NUP — duplicated for the loader)
  DBMS_OUTPUT.PUT_LINE('"extended":{');
  DBMS_OUTPUT.PUT_LINE('  "run_id":"'    || v_run_id || '",');
  DBMS_OUTPUT.PUT_LINE('  "hostname":"' || j(v_hostname) || '",');
  DBMS_OUTPUT.PUT_LINE('  "instances":['|| v_instances_json || ']');
  DBMS_OUTPUT.PUT_LINE('},');

  -- OPTIONS payload
  DBMS_OUTPUT.PUT_LINE('"options":['         || v_options_json || '],');

  -- DB_PARAMETERS payload (raw GV$PARAMETER values for loader reference)
  DBMS_OUTPUT.PUT_LINE('"db_parameters":['   || v_params_json  || ']');
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
PROMPT  Discovery complete.
PROMPT  Output file: &sam_outfile
PROMPT  Next step  : python3 scripts/load_discovery.py &sam_outfile
PROMPT ============================================================

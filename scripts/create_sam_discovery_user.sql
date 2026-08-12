-- =============================================================================
-- create_sam_discovery_user.sql
--
-- Creates a least-privileged Oracle database user for running the Helios
-- discovery scripts (oracle_discovery.sql / oracle_discovery_csv.sql).
--
-- Run as SYSDBA on each target database:
--   sqlplus / as sysdba @create_sam_discovery_user.sql
--
-- The user is granted SELECT-only access on the exact views and tables
-- queried by the discovery scripts.  No DBA role, no ANY privilege.
--
-- After running, update run_discovery.sh / run_discovery_csv.sh to connect
-- as sam_discovery rather than sys/sysdba.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Create user
--    Change the password before running in production.
-- ---------------------------------------------------------------------------
CREATE USER sam_discovery IDENTIFIED BY "ChangeMe123!"
  DEFAULT TABLESPACE users
  TEMPORARY TABLESPACE temp
  QUOTA 0 ON users;          -- no DDL; prevent accidental space usage

-- ---------------------------------------------------------------------------
-- 2. Session privilege — needed to log in
-- ---------------------------------------------------------------------------
GRANT CREATE SESSION TO sam_discovery;

-- ---------------------------------------------------------------------------
-- 3. Dynamic performance views (v$ / gv$)
--    These are synonyms for SYS-owned objects; GRANT SELECT works directly.
-- ---------------------------------------------------------------------------
GRANT SELECT ON v_$database          TO sam_discovery;
GRANT SELECT ON v_$instance          TO sam_discovery;
GRANT SELECT ON v_$version           TO sam_discovery;
GRANT SELECT ON v_$osstat            TO sam_discovery;
GRANT SELECT ON v_$parameter         TO sam_discovery;
GRANT SELECT ON v_$option            TO sam_discovery;
GRANT SELECT ON v_$pdbs              TO sam_discovery;
GRANT SELECT ON v_$cell              TO sam_discovery;  -- Exadata only; harmless on non-Exadata

-- RAC: gv$ views (also SYS-owned)
GRANT SELECT ON gv_$instance         TO sam_discovery;
GRANT SELECT ON gv_$parameter        TO sam_discovery;

-- ---------------------------------------------------------------------------
-- 4. Data dictionary views
-- ---------------------------------------------------------------------------
GRANT SELECT ON dba_users                    TO sam_discovery;
GRANT SELECT ON dba_feature_usage_statistics TO sam_discovery;

-- ---------------------------------------------------------------------------
-- 5. Verify — run as sam_discovery to confirm access
-- ---------------------------------------------------------------------------
--   SELECT name, db_unique_name FROM v$database;
--   SELECT instance_name, status FROM v$instance;
--   SELECT stat_name, value FROM v$osstat WHERE stat_name = 'NUM_CPU_SOCKETS';
--   SELECT name, value FROM v$parameter WHERE name = 'cell_offload_processing';
--   SELECT * FROM v$option WHERE PARAMETER = 'Partitioning';
--   SELECT con_id, name FROM v$pdbs;
--   SELECT username, account_status FROM dba_users WHERE oracle_maintained = 'N';
--   SELECT name, currently_used, detected_usages
--     FROM dba_feature_usage_statistics WHERE ROWNUM <= 5;
-- ---------------------------------------------------------------------------

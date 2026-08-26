-- =============================================================================
-- create_sam_discovery_user.sql
-- Creates the least-privilege SAM discovery account in a CDB or non-CDB.
--
-- Run as SYSDBA from CDB$ROOT (or from the sole instance of a non-CDB):
--   sqlplus / as sysdba @create_sam_discovery_user.sql
--
-- In a CDB the account is a COMMON USER (C##SAM_DISCOVERY) so it can
-- connect to any PDB and to CDB$ROOT.  In a non-CDB a regular local user
-- is created instead.
--
-- You will be prompted for the password at runtime — it is never stored
-- in this script or in the shell history.
-- =============================================================================

SET VERIFY OFF
SET FEEDBACK OFF

-- Prompt for password (input is not echoed in SQL*Plus >= 12.2; on older
-- versions advise the DBA to clear their terminal history after running).
ACCEPT sam_pwd PROMPT "Enter password for SAM discovery account: " HIDE

-- =============================================================================
-- Detect CDB vs non-CDB so we use the right username prefix.
-- CDB common users MUST start with C## (ORA-65096 if they don't).
-- =============================================================================
COLUMN _is_cdb NEW_VALUE _is_cdb NOPRINT
SELECT cdb AS _is_cdb FROM v$database;

COLUMN _username NEW_VALUE _username NOPRINT
SELECT CASE WHEN '&_is_cdb' = 'YES' THEN 'C##SAM_DISCOVERY'
            ELSE 'SAM_DISCOVERY' END AS _username
FROM dual;

SET FEEDBACK ON
PROMPT
PROMPT Creating user &_username ...
PROMPT

-- =============================================================================
-- Create the user
-- In a CDB: CONTAINER=ALL makes it a common user visible in all PDBs.
-- In a non-CDB: CONTAINER=ALL is ignored / not needed.
-- =============================================================================
DECLARE
  v_sql VARCHAR2(500);
BEGIN
  v_sql := 'CREATE USER &_username IDENTIFIED BY "&sam_pwd"'
        || CASE WHEN '&_is_cdb' = 'YES' THEN ' CONTAINER=ALL' ELSE '' END;
  EXECUTE IMMEDIATE v_sql;
  DBMS_OUTPUT.PUT_LINE('User &_username created.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -1920 THEN
      DBMS_OUTPUT.PUT_LINE('User &_username already exists — resetting password.');
      EXECUTE IMMEDIATE 'ALTER USER &_username IDENTIFIED BY "&sam_pwd"'
                     || CASE WHEN '&_is_cdb' = 'YES' THEN ' CONTAINER=ALL' ELSE '' END;
    ELSE
      RAISE;
    END IF;
END;
/
SET SERVEROUTPUT ON

-- =============================================================================
-- Session privilege — needed to connect at all.
-- In a CDB: CONTAINER=ALL grants it across root + all PDBs.
-- =============================================================================
BEGIN
  IF '&_is_cdb' = 'YES' THEN
    EXECUTE IMMEDIATE 'GRANT CREATE SESSION TO &_username CONTAINER=ALL';
  ELSE
    EXECUTE IMMEDIATE 'GRANT CREATE SESSION TO &_username';
  END IF;
END;
/

-- =============================================================================
-- Read-only SELECT on the views the discovery scripts query.
-- All views below are accessible from CDB$ROOT (and most from a PDB too).
-- =============================================================================
-- Core instance / database views
GRANT SELECT ON SYS.V_$INSTANCE             TO &_username;
GRANT SELECT ON SYS.V_$DATABASE             TO &_username;
GRANT SELECT ON SYS.V_$VERSION              TO &_username;
GRANT SELECT ON SYS.V_$PARAMETER            TO &_username;
GRANT SELECT ON SYS.V_$OPTION               TO &_username;
GRANT SELECT ON SYS.V_$OSSTAT               TO &_username;
GRANT SELECT ON SYS.V_$FIXED_TABLE          TO &_username;
GRANT SELECT ON SYS.V_$PDBS                 TO &_username;

-- RAC / global views
GRANT SELECT ON SYS.GV_$INSTANCE            TO &_username;
GRANT SELECT ON SYS.GV_$PARAMETER           TO &_username;

-- Feature / licence usage
GRANT SELECT ON SYS.DBA_FEATURE_USAGE_STATISTICS TO &_username;
GRANT SELECT ON SYS.DBA_USERS               TO &_username;

-- CDB-level feature usage (CDB$ROOT only; view absent in non-CDB — skip if so)
BEGIN
  EXECUTE IMMEDIATE 'GRANT SELECT ON SYS.CDB_FEATURE_USAGE_STATISTICS TO &_username';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

-- Exadata cell detection (view present only on Exadata hosts — skip if absent)
BEGIN
  EXECUTE IMMEDIATE 'GRANT SELECT ON SYS.V_$CELL TO &_username';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

PROMPT
PROMPT ============================================================
PROMPT  SAM discovery account ready: &_username
PROMPT
PROMPT  Connect string examples:
PROMPT    sqlplus &_username/<password>@<cdb_service>
PROMPT    sqlplus &_username/<password>@<pdb_service>
PROMPT
PROMPT  Run discovery:
PROMPT    ./scripts/run_discovery_csv.sh "&_username/<password>@<service>"
PROMPT ============================================================
PROMPT

-- Clear the password substitution variable from memory
UNDEFINE sam_pwd
UNDEFINE _is_cdb
UNDEFINE _username

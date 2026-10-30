-- Run ON the database host, as the account Ansible uses, to find why an
-- instance returns no output. Use the SAME ORACLE_HOME and ORACLE_SID the
-- playbook used, e.g.
--
--   export ORACLE_HOME=/opt/oracle/product/26ai/dbhome_1
--   export ORACLE_SID=ORCLCDB
--   export PATH=$ORACLE_HOME/bin:$PATH
--   sqlplus -s / as sysdba @diagnose_sqlplus_no_output.sql
--
-- Note: no "-s". Run it without silent mode too, so connection errors show:
--   sqlplus / as sysdba @diagnose_sqlplus_no_output.sql
--
-- Every step prints a line. A step that prints nothing is where it breaks.

SET PAGESIZE 50 FEEDBACK OFF HEADING OFF ECHO OFF LINESIZE 200
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT == 1. connected at all? ==
SELECT 'connected as ' || SYS_CONTEXT('USERENV','SESSION_USER')
     || ' to ' || SYS_CONTEXT('USERENV','DB_NAME')
     || ', instance ' || SYS_CONTEXT('USERENV','INSTANCE_NAME') AS r FROM dual;

PROMPT
PROMPT == 2. instance status (OPEN needed for v$database) ==
SELECT 'instance_name=' || instance_name
     || ' status='      || status
     || ' database_status=' || database_status
     || ' version='     || version AS r
FROM   v$instance;

PROMPT
PROMPT == 3. v$version rows, and whether the playbook LIKE matches ==
SELECT 'banner=[' || banner || ']  matches_oracle_database='
     || CASE WHEN UPPER(banner) LIKE '%ORACLE DATABASE%' THEN 'YES' ELSE 'NO' END AS r
FROM   v$version;

PROMPT
PROMPT == 4. the exact subquery the playbook used (blank line here = the bug) ==
SELECT 'subquery returned: [' || banner || ']' AS r
FROM   (SELECT banner FROM v$version
        WHERE  UPPER(banner) LIKE '%ORACLE DATABASE%'
        AND    ROWNUM = 1);

PROMPT
PROMPT == 5. v$database columns the playbook reads ==
SELECT 'name=' || name || ' cdb=' || cdb || ' log_mode=' || log_mode AS r
FROM   v$database;

PROMPT
PROMPT == 6. the playbook query as it stands (blank = returns zero rows) ==
SELECT 'OLD form returned a row: ' || SUBSTR(i.version,1,20) AS r
FROM   v$instance i
CROSS  JOIN v$database d
CROSS  JOIN (SELECT banner FROM v$version
             WHERE  UPPER(banner) LIKE '%ORACLE DATABASE%'
             AND    ROWNUM = 1) v;

PROMPT
PROMPT == 7. the hardened form, which must always return exactly one row ==
SELECT 'NEW form returned a row: ' || SUBSTR(i.version,1,20)
     || ' edition_banner=[' || SUBSTR(v.banner,1,60) || ']' AS r
FROM   v$instance i
CROSS  JOIN v$database d
CROSS  JOIN (SELECT COALESCE(
               (SELECT MAX(banner) FROM v$version
                 WHERE UPPER(banner) LIKE '%ORACLE DATABASE%'),
               (SELECT MAX(banner) FROM v$version),
               'Unknown') AS banner
             FROM dual) v;

PROMPT
PROMPT == done ==
EXIT

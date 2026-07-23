-- =============================================================================
-- Create SAM Discovery Oracle Account (Least Privilege)
--
-- This script creates a minimal read-only Oracle account used by the
-- Helios Oracle SAM discovery playbook (discover_oracle_leastpriv.yml).
--
-- It replaces the need to connect as / AS SYSDBA or use the oracle OS user.
--
-- Run as: sqlplus sys/<password>@<tns_alias> AS SYSDBA @create_sam_discovery_user.sql
--
-- After running, set the password in your Ansible vault:
--   ansible_vault_sam_discovery_password: <the password you chose>
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Create the user
--    No quota needed — this account never creates objects.
-- ---------------------------------------------------------------------------
CREATE USER sam_discovery IDENTIFIED BY "ChangeMe_S@mD1sc0very!"
  DEFAULT TABLESPACE users
  TEMPORARY TABLESPACE temp;

-- ---------------------------------------------------------------------------
-- 2. Login only
-- ---------------------------------------------------------------------------
GRANT CREATE SESSION TO sam_discovery;

-- ---------------------------------------------------------------------------
-- 3. Dynamic performance views
--    All read-only; grants go to the underlying V_ synonym base objects.
-- ---------------------------------------------------------------------------
GRANT SELECT ON V_$INSTANCE   TO sam_discovery;   -- hostname, version, instance name
GRANT SELECT ON V_$DATABASE   TO sam_discovery;   -- edition, CDB flag, platform, log_mode
GRANT SELECT ON V_$OPTION     TO sam_discovery;   -- licensed options & features
GRANT SELECT ON V_$OSSTAT     TO sam_discovery;   -- CPU sockets, cores, RAM
GRANT SELECT ON V_$PARAMETER  TO sam_discovery;   -- cpu_type, processor_type
GRANT SELECT ON V_$PDBS       TO sam_discovery;   -- PDB topology (Multitenant licensing)

-- RAC: GV$ views expose all cluster nodes; only needed on RAC environments.
-- Safe to grant on non-RAC — it simply returns one row.
GRANT SELECT ON GV_$INSTANCE  TO sam_discovery;   -- RAC node count and names

-- ---------------------------------------------------------------------------
-- 4. Data dictionary views
-- ---------------------------------------------------------------------------
GRANT SELECT ON DBA_REGISTRY  TO sam_discovery;   -- installed DB components & status
GRANT SELECT ON DBA_USERS     TO sam_discovery;   -- Named User Plus counting

-- ---------------------------------------------------------------------------
-- 5. Verify grants
-- ---------------------------------------------------------------------------
SELECT privilege, object_name
FROM   dba_tab_privs
WHERE  grantee = 'SAM_DISCOVERY'
ORDER  BY object_name;

PROMPT
PROMPT ============================================================
PROMPT  sam_discovery account created successfully.
PROMPT
PROMPT  IMPORTANT: Change the password before use:
PROMPT    ALTER USER sam_discovery IDENTIFIED BY "<new_password>";
PROMPT
PROMPT  Then store it in your Ansible vault:
PROMPT    ansible-vault edit group_vars/all/vault.yml
PROMPT    Set: vault_sam_discovery_password: <new_password>
PROMPT ============================================================

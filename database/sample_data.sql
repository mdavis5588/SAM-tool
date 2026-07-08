-- =============================================================================
-- Sample discovery data — 12 Oracle DB servers with varied option usage
-- Run against your oracle_sam database:
--   sudo -u postgres psql oracle_sam -f database/sample_data.sql
--
-- Change 'client_acme' to your actual client schema if different.
-- =============================================================================

-- Clear existing sample data so the script is re-runnable
DELETE FROM client_acme.oracle_options
  WHERE instance_id IN (
    SELECT i.instance_id FROM client_acme.oracle_instances i
    JOIN client_acme.oracle_servers s ON s.server_id = i.server_id
    WHERE s.hostname IN (
      'db-prod-01','db-prod-02','db-prod-03','db-prod-04',
      'db-dr-01','db-dr-02',
      'db-uat-01','db-uat-02',
      'db-dev-01','db-dev-02',
      'db-legacy-01','db-reporting-01'
    )
  );
DELETE FROM client_acme.oracle_instances
  WHERE server_id IN (
    SELECT server_id FROM client_acme.oracle_servers
    WHERE hostname IN (
      'db-prod-01','db-prod-02','db-prod-03','db-prod-04',
      'db-dr-01','db-dr-02',
      'db-uat-01','db-uat-02',
      'db-dev-01','db-dev-02',
      'db-legacy-01','db-reporting-01'
    )
  );
DELETE FROM client_acme.oracle_processors
  WHERE server_id IN (
    SELECT server_id FROM client_acme.oracle_servers
    WHERE hostname IN (
      'db-prod-01','db-prod-02','db-prod-03','db-prod-04',
      'db-dr-01','db-dr-02',
      'db-uat-01','db-uat-02',
      'db-dev-01','db-dev-02',
      'db-legacy-01','db-reporting-01'
    )
  );
DELETE FROM client_acme.oracle_servers
  WHERE hostname IN (
    'db-prod-01','db-prod-02','db-prod-03','db-prod-04',
    'db-dr-01','db-dr-02',
    'db-uat-01','db-uat-02',
    'db-dev-01','db-dev-02',
    'db-legacy-01','db-reporting-01'
  );

-- ---------------------------------------------------------------------------
-- 1. Servers
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_servers
  (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
   environment, criticality, total_ram_mb, datacenter, is_active, last_seen)
VALUES
  -- Production EE physical boxes (heavy options)
  ('db-prod-01',     'db-prod-01.acme.internal',     '10.0.1.11', 'Linux', 'Red Hat Enterprise Linux', '8.9',  'production',  'HIGH',   262144, 'LON-DC1', TRUE, NOW()),
  ('db-prod-02',     'db-prod-02.acme.internal',     '10.0.1.12', 'Linux', 'Red Hat Enterprise Linux', '8.9',  'production',  'HIGH',   262144, 'LON-DC1', TRUE, NOW()),
  -- Production EE VMware (capped vCPUs)
  ('db-prod-03',     'db-prod-03.acme.internal',     '10.0.1.13', 'Linux', 'Oracle Linux',             '8.8',  'production',  'HIGH',    65536, 'LON-DC1', TRUE, NOW()),
  ('db-prod-04',     'db-prod-04.acme.internal',     '10.0.1.14', 'Linux', 'Oracle Linux',             '8.8',  'production',  'MEDIUM',  32768, 'LON-DC1', TRUE, NOW()),
  -- DR mirrors (physical)
  ('db-dr-01',       'db-dr-01.acme.internal',       '10.0.2.11', 'Linux', 'Red Hat Enterprise Linux', '8.9',  'dr',          'HIGH',   262144, 'MAN-DC2', TRUE, NOW()),
  ('db-dr-02',       'db-dr-02.acme.internal',       '10.0.2.12', 'Linux', 'Oracle Linux',             '8.8',  'dr',          'MEDIUM',  65536, 'MAN-DC2', TRUE, NOW()),
  -- UAT — EE with some options, SE2 with none
  ('db-uat-01',      'db-uat-01.acme.internal',      '10.0.3.11', 'Linux', 'Red Hat Enterprise Linux', '7.9',  'test',        'MEDIUM',  32768, 'LON-DC1', TRUE, NOW()),
  ('db-uat-02',      'db-uat-02.acme.internal',      '10.0.3.12', 'Linux', 'Oracle Linux',             '8.8',  'test',        'LOW',     16384, 'LON-DC1', TRUE, NOW()),
  -- Dev — SE2 only (no licensable options)
  ('db-dev-01',      'db-dev-01.acme.internal',      '10.0.4.11', 'Linux', 'Oracle Linux',             '8.8',  'development', 'LOW',     16384, 'LON-DC1', TRUE, NOW()),
  ('db-dev-02',      'db-dev-02.acme.internal',      '10.0.4.12', 'Linux', 'Red Hat Enterprise Linux', '8.9',  'development', 'LOW',      8192, 'LON-DC1', TRUE, NOW()),
  -- Legacy 12c production (still in use, several options)
  ('db-legacy-01',   'db-legacy-01.acme.internal',   '10.0.5.11', 'Linux', 'Red Hat Enterprise Linux', '6.10', 'production',  'HIGH',    65536, 'LON-DC1', TRUE, NOW()),
  -- Reporting server — EE, heavy analytics options
  ('db-reporting-01','db-reporting-01.acme.internal','10.0.1.21', 'Linux', 'Oracle Linux',             '8.8',  'production',  'MEDIUM', 131072, 'LON-DC1', TRUE, NOW());

-- ---------------------------------------------------------------------------
-- 2. Processors
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_processors
  (server_id, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
   threads_per_core, virt_type, is_vmware, vcpu_count)
SELECT s.server_id, v.cpu_model, 'x86_64',
       v.cpu_sockets, v.cores_per_socket, 2,
       v.virt_type::client_acme.virt_type, v.is_vmware, v.vcpu_count
FROM (VALUES
  -- physical prod: 2 sockets × 32 cores = 64 physical cores
  ('db-prod-01',     'Intel Xeon Gold 6338',   2, 32, 'physical', FALSE, NULL),
  ('db-prod-02',     'Intel Xeon Gold 6338',   2, 32, 'physical', FALSE, NULL),
  -- VMware prod: capped at 16 vCPUs each
  ('db-prod-03',     'Intel Xeon Gold 6338',   2, 16, 'vmware',   TRUE,  16),
  ('db-prod-04',     'Intel Xeon Gold 6338',   2,  8, 'vmware',   TRUE,   8),
  -- DR physical
  ('db-dr-01',       'Intel Xeon Gold 6338',   2, 32, 'physical', FALSE, NULL),
  ('db-dr-02',       'Intel Xeon Gold 6338',   2, 16, 'vmware',   TRUE,  16),
  -- UAT VMware
  ('db-uat-01',      'Intel Xeon Silver 4314', 2,  8, 'vmware',   TRUE,   8),
  ('db-uat-02',      'Intel Xeon Silver 4314', 2,  4, 'vmware',   TRUE,   4),
  -- Dev VMware (small)
  ('db-dev-01',      'Intel Xeon Silver 4214', 1,  4, 'vmware',   TRUE,   4),
  ('db-dev-02',      'Intel Xeon Silver 4214', 1,  2, 'vmware',   TRUE,   2),
  -- Legacy physical (older CPUs, core factor 0.5)
  ('db-legacy-01',   'Intel Xeon E5-2690 v4',  2, 14, 'physical', FALSE, NULL),
  -- Reporting physical
  ('db-reporting-01','Intel Xeon Gold 6338',   2, 32, 'physical', FALSE, NULL)
) AS v(hostname, cpu_model, cpu_sockets, cores_per_socket, virt_type, is_vmware, vcpu_count)
JOIN client_acme.oracle_servers s USING (hostname);

-- ---------------------------------------------------------------------------
-- 3. Oracle Instances
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_instances
  (server_id, oracle_sid, db_name, oracle_home, edition, db_version,
   platform_name, autostart, is_active)
SELECT s.server_id, v.oracle_sid, v.db_name, v.oracle_home,
       v.edition, v.db_version, 'Linux x86 64-bit', TRUE, TRUE
FROM (VALUES
  -- Production EE 19c
  ('db-prod-01',     'ERPDB',    'ERPDB',    '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0'),
  ('db-prod-02',     'FINDB',    'FINDB',    '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0'),
  ('db-prod-03',     'HRDB',     'HRDB',     '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0'),
  ('db-prod-04',     'CRMDB',    'CRMDB',    '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0'),
  -- DR EE 19c
  ('db-dr-01',       'ERPDB',    'ERPDB',    '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0'),
  ('db-dr-02',       'FINDB',    'FINDB',    '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0'),
  -- UAT EE 19c / SE2 19c
  ('db-uat-01',      'UATDB',    'UATDB',    '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0'),
  ('db-uat-02',      'UATSE2',   'UATSE2',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Standard Edition 2',   '19.3.0.0.0'),
  -- Dev SE2 19c
  ('db-dev-01',      'DEVDB1',   'DEVDB1',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Standard Edition 2',   '19.3.0.0.0'),
  ('db-dev-02',      'DEVDB2',   'DEVDB2',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Standard Edition 2',   '19.3.0.0.0'),
  -- Legacy EE 12c
  ('db-legacy-01',   'LEGACYDB', 'LEGACYDB', '/u01/app/oracle/product/12.2.0/dbhome_1', 'Oracle Database 12c Enterprise Edition', '12.2.0.1.0'),
  -- Reporting EE 19c
  ('db-reporting-01','RPTDB',    'RPTDB',    '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0')
) AS v(hostname, oracle_sid, db_name, oracle_home, edition, db_version)
JOIN client_acme.oracle_servers s USING (hostname)
ON CONFLICT (server_id, oracle_sid) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. Oracle Options  (v$option TRUE = in-use, FALSE = available but not used)
--
-- Licensable options in play:
--   Partitioning            — very common on EE
--   Advanced Security       — TDE / network encryption
--   Diagnostics Pack        — AWR, ADDM, ASH
--   Tuning Pack             — SQL Tuning Advisor (requires Diagnostics Pack)
--   Advanced Compression    — table / RMAN compression
--   Database Vault          — separation of duties / privileged user controls
--   Label Security          — row-level classification / sensitivity labels
--   Spatial and Graph       — geo / graph analytics
--   OLAP                    — multidimensional cube engine
--   Data Mining             — in-database ML (OAA)
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_options (instance_id, option_name, option_version, status)
SELECT i.instance_id, v.option_name, v.option_version, v.status
FROM (VALUES

  -- ── db-prod-01 / ERPDB  (flagship ERP — full suite of options) ──────────
  ('db-prod-01','ERPDB', 'Partitioning',         '19.0.0.0.0', 'TRUE'),
  ('db-prod-01','ERPDB', 'Advanced Security',    '19.0.0.0.0', 'TRUE'),
  ('db-prod-01','ERPDB', 'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('db-prod-01','ERPDB', 'Tuning Pack',          '19.0.0.0.0', 'TRUE'),
  ('db-prod-01','ERPDB', 'Advanced Compression', '19.0.0.0.0', 'TRUE'),
  ('db-prod-01','ERPDB', 'Database Vault',       '19.0.0.0.0', 'TRUE'),
  ('db-prod-01','ERPDB', 'Label Security',       '19.0.0.0.0', 'FALSE'),
  ('db-prod-01','ERPDB', 'Real Application Clusters','19.0.0.0.0','FALSE'),

  -- ── db-prod-02 / FINDB  (finance — security + compression focus) ─────────
  ('db-prod-02','FINDB', 'Partitioning',         '19.0.0.0.0', 'TRUE'),
  ('db-prod-02','FINDB', 'Advanced Security',    '19.0.0.0.0', 'TRUE'),
  ('db-prod-02','FINDB', 'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('db-prod-02','FINDB', 'Tuning Pack',          '19.0.0.0.0', 'TRUE'),
  ('db-prod-02','FINDB', 'Advanced Compression', '19.0.0.0.0', 'TRUE'),
  ('db-prod-02','FINDB', 'Database Vault',       '19.0.0.0.0', 'TRUE'),
  ('db-prod-02','FINDB', 'Label Security',       '19.0.0.0.0', 'TRUE'),
  ('db-prod-02','FINDB', 'Real Application Clusters','19.0.0.0.0','FALSE'),

  -- ── db-prod-03 / HRDB  (VMware EE — lighter options) ─────────────────────
  ('db-prod-03','HRDB',  'Partitioning',         '19.0.0.0.0', 'TRUE'),
  ('db-prod-03','HRDB',  'Advanced Security',    '19.0.0.0.0', 'TRUE'),
  ('db-prod-03','HRDB',  'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('db-prod-03','HRDB',  'Advanced Compression', '19.0.0.0.0', 'FALSE'),
  ('db-prod-03','HRDB',  'Tuning Pack',          '19.0.0.0.0', 'FALSE'),

  -- ── db-prod-04 / CRMDB  (VMware EE — diagnostics only) ───────────────────
  ('db-prod-04','CRMDB', 'Partitioning',         '19.0.0.0.0', 'FALSE'),
  ('db-prod-04','CRMDB', 'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('db-prod-04','CRMDB', 'Tuning Pack',          '19.0.0.0.0', 'TRUE'),
  ('db-prod-04','CRMDB', 'Advanced Compression', '19.0.0.0.0', 'FALSE'),

  -- ── db-dr-01 / ERPDB  (DR mirror — same options as prod) ─────────────────
  ('db-dr-01',  'ERPDB', 'Partitioning',         '19.0.0.0.0', 'TRUE'),
  ('db-dr-01',  'ERPDB', 'Advanced Security',    '19.0.0.0.0', 'TRUE'),
  ('db-dr-01',  'ERPDB', 'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('db-dr-01',  'ERPDB', 'Tuning Pack',          '19.0.0.0.0', 'TRUE'),
  ('db-dr-01',  'ERPDB', 'Advanced Compression', '19.0.0.0.0', 'TRUE'),
  ('db-dr-01',  'ERPDB', 'Database Vault',       '19.0.0.0.0', 'TRUE'),

  -- ── db-dr-02 / FINDB  (DR mirror — reduced options) ──────────────────────
  ('db-dr-02',  'FINDB', 'Partitioning',         '19.0.0.0.0', 'TRUE'),
  ('db-dr-02',  'FINDB', 'Advanced Security',    '19.0.0.0.0', 'TRUE'),
  ('db-dr-02',  'FINDB', 'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('db-dr-02',  'FINDB', 'Advanced Compression', '19.0.0.0.0', 'TRUE'),

  -- ── db-uat-01 / UATDB  (EE test — partitioning + diagnostics only) ───────
  ('db-uat-01', 'UATDB', 'Partitioning',         '19.0.0.0.0', 'TRUE'),
  ('db-uat-01', 'UATDB', 'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('db-uat-01', 'UATDB', 'Tuning Pack',          '19.0.0.0.0', 'FALSE'),
  ('db-uat-01', 'UATDB', 'Advanced Security',    '19.0.0.0.0', 'FALSE'),

  -- db-uat-02 is SE2 — no licensable options apply

  -- db-dev-01, db-dev-02 are SE2 — no licensable options apply

  -- ── db-legacy-01 / LEGACYDB  (12c EE — older option set) ─────────────────
  ('db-legacy-01','LEGACYDB','Partitioning',         '12.2.0.1.0', 'TRUE'),
  ('db-legacy-01','LEGACYDB','Advanced Security',    '12.2.0.1.0', 'TRUE'),
  ('db-legacy-01','LEGACYDB','Diagnostics Pack',     '12.2.0.1.0', 'TRUE'),
  ('db-legacy-01','LEGACYDB','Tuning Pack',          '12.2.0.1.0', 'TRUE'),
  ('db-legacy-01','LEGACYDB','OLAP',                 '12.2.0.1.0', 'TRUE'),
  ('db-legacy-01','LEGACYDB','Spatial and Graph',    '12.2.0.1.0', 'TRUE'),
  ('db-legacy-01','LEGACYDB','Data Mining',          '12.2.0.1.0', 'FALSE'),

  -- ── db-reporting-01 / RPTDB  (analytics box — OLAP + Spatial + Data Mining) ──
  ('db-reporting-01','RPTDB','Partitioning',         '19.0.0.0.0', 'TRUE'),
  ('db-reporting-01','RPTDB','Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('db-reporting-01','RPTDB','Tuning Pack',          '19.0.0.0.0', 'TRUE'),
  ('db-reporting-01','RPTDB','Advanced Compression', '19.0.0.0.0', 'TRUE'),
  ('db-reporting-01','RPTDB','OLAP',                 '19.0.0.0.0', 'TRUE'),
  ('db-reporting-01','RPTDB','Spatial and Graph',    '19.0.0.0.0', 'TRUE'),
  ('db-reporting-01','RPTDB','Data Mining',          '19.0.0.0.0', 'TRUE'),
  ('db-reporting-01','RPTDB','Advanced Security',    '19.0.0.0.0', 'FALSE')

) AS v(hostname, oracle_sid, option_name, option_version, status)
JOIN client_acme.oracle_servers   s ON s.hostname    = v.hostname
JOIN client_acme.oracle_instances i ON i.server_id   = s.server_id
                                   AND i.oracle_sid  = v.oracle_sid;

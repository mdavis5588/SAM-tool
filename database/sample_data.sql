-- =============================================================================
-- Sample discovery data — 10 Oracle servers for testing
-- Run against your oracle_sam database:
--   psql oracle_sam -f database/sample_data.sql
--
-- Change 'client_acme' below to your actual client schema if different.
-- =============================================================================

SET search_path = client_acme, public;

-- ---------------------------------------------------------------------------
-- 1. Servers
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_servers
  (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
   environment, criticality, total_ram_mb, datacenter, is_active)
VALUES
  ('db-prod-01',  'db-prod-01.acme.internal',  '10.0.1.11', 'Linux', 'Red Hat Enterprise Linux', '8.8',  'production',    'HIGH',   131072, 'LON-DC1', TRUE),
  ('db-prod-02',  'db-prod-02.acme.internal',  '10.0.1.12', 'Linux', 'Red Hat Enterprise Linux', '8.8',  'production',    'HIGH',   131072, 'LON-DC1', TRUE),
  ('db-prod-03',  'db-prod-03.acme.internal',  '10.0.1.13', 'Linux', 'Oracle Linux',             '8.7',  'production',    'HIGH',    65536, 'LON-DC1', TRUE),
  ('db-dr-01',    'db-dr-01.acme.internal',    '10.0.2.11', 'Linux', 'Red Hat Enterprise Linux', '8.8',  'dr',            'HIGH',   131072, 'MAN-DC2', TRUE),
  ('db-dr-02',    'db-dr-02.acme.internal',    '10.0.2.12', 'Linux', 'Oracle Linux',             '8.7',  'dr',            'MEDIUM',  65536, 'MAN-DC2', TRUE),
  ('db-uat-01',   'db-uat-01.acme.internal',   '10.0.3.11', 'Linux', 'Red Hat Enterprise Linux', '7.9',  'test',          'MEDIUM',  32768, 'LON-DC1', TRUE),
  ('db-uat-02',   'db-uat-02.acme.internal',   '10.0.3.12', 'Linux', 'Oracle Linux',             '8.7',  'test',          'LOW',     16384, 'LON-DC1', TRUE),
  ('db-dev-01',   'db-dev-01.acme.internal',   '10.0.4.11', 'Linux', 'Red Hat Enterprise Linux', '8.8',  'development',   'LOW',     16384, 'LON-DC1', TRUE),
  ('db-dev-02',   'db-dev-02.acme.internal',   '10.0.4.12', 'Linux', 'Oracle Linux',             '7.9',  'development',   'LOW',      8192, 'LON-DC1', TRUE),
  ('db-legacy-01','db-legacy-01.acme.internal','10.0.5.11', 'Linux', 'Red Hat Enterprise Linux', '6.10', 'production',    'HIGH',    32768, 'LON-DC1', TRUE)
ON CONFLICT (hostname) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Processors
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_processors
  (server_id, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
   threads_per_core, virt_type, is_vmware, vcpu_count)
SELECT server_id, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
       threads_per_core, virt_type::client_acme.virt_type, is_vmware, vcpu_count
FROM (VALUES
  ('db-prod-01',  'Intel Xeon Gold 6338',  'x86_64', 2, 32, 2, 'physical', FALSE, NULL),
  ('db-prod-02',  'Intel Xeon Gold 6338',  'x86_64', 2, 32, 2, 'physical', FALSE, NULL),
  ('db-prod-03',  'Intel Xeon Silver 4314','x86_64', 2, 16, 2, 'vmware',   TRUE,  16),
  ('db-dr-01',    'Intel Xeon Gold 6338',  'x86_64', 2, 32, 2, 'physical', FALSE, NULL),
  ('db-dr-02',    'Intel Xeon Silver 4314','x86_64', 2, 16, 2, 'vmware',   TRUE,  16),
  ('db-uat-01',   'Intel Xeon Silver 4214','x86_64', 2,  8, 2, 'vmware',   TRUE,   8),
  ('db-uat-02',   'Intel Xeon Silver 4214','x86_64', 2,  8, 2, 'vmware',   TRUE,   8),
  ('db-dev-01',   'Intel Xeon Silver 4214','x86_64', 1,  4, 2, 'vmware',   TRUE,   4),
  ('db-dev-02',   'Intel Xeon Silver 4214','x86_64', 1,  4, 2, 'vmware',   TRUE,   4),
  ('db-legacy-01','Intel Xeon E5-2690 v4', 'x86_64', 2, 14, 2, 'physical', FALSE, NULL)
) AS v(hostname, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
       threads_per_core, virt_type, is_vmware, vcpu_count)
JOIN client_acme.oracle_servers s USING (hostname);

-- ---------------------------------------------------------------------------
-- 3. Oracle Instances
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_instances
  (server_id, oracle_sid, db_name, oracle_home, edition, db_version,
   platform_name, autostart, is_active)
SELECT s.server_id, v.oracle_sid, v.db_name, v.oracle_home, v.edition,
       v.db_version, v.platform_name, v.autostart, TRUE
FROM (VALUES
  ('db-prod-01',  'PRODDB1', 'PRODDB1', '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-prod-01',  'PRODDB2', 'PRODDB2', '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-prod-02',  'FINDB',   'FINDB',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-prod-03',  'HRDB',    'HRDB',    '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-dr-01',    'PRODDB1', 'PRODDB1', '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-dr-01',    'PRODDB2', 'PRODDB2', '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-dr-02',    'FINDB',   'FINDB',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-uat-01',   'UATDB1',  'UATDB1',  '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-uat-02',   'UATDB2',  'UATDB2',  '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Standard Edition 2', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-dev-01',   'DEVDB1',  'DEVDB1',  '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Standard Edition 2', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-dev-02',   'DEVDB2',  'DEVDB2',  '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Standard Edition 2', '19.3.0.0.0', 'Linux x86 64-bit', TRUE),
  ('db-legacy-01','LEGACYDB','LEGACYDB','/u01/app/oracle/product/12.2.0/dbhome_1', 'Oracle Database 12c Enterprise Edition', '12.2.0.1.0', 'Linux x86 64-bit', TRUE)
) AS v(hostname, oracle_sid, db_name, oracle_home, edition, db_version, platform_name, autostart)
JOIN client_acme.oracle_servers s USING (hostname)
ON CONFLICT (server_id, oracle_sid) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. Oracle Options (v$option flags)
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_options (instance_id, option_name, option_version, status)
SELECT i.instance_id, v.option_name, v.option_version, v.status
FROM (VALUES
  -- Production servers use several licensed options
  ('db-prod-01', 'PRODDB1', 'Partitioning',              '19.0.0.0.0', 'TRUE'),
  ('db-prod-01', 'PRODDB1', 'Real Application Clusters', '19.0.0.0.0', 'FALSE'),
  ('db-prod-01', 'PRODDB1', 'Diagnostics Pack',          '19.0.0.0.0', 'TRUE'),
  ('db-prod-01', 'PRODDB1', 'Tuning Pack',               '19.0.0.0.0', 'TRUE'),
  ('db-prod-01', 'PRODDB1', 'Advanced Compression',      '19.0.0.0.0', 'TRUE'),
  ('db-prod-01', 'PRODDB2', 'Partitioning',              '19.0.0.0.0', 'TRUE'),
  ('db-prod-01', 'PRODDB2', 'Diagnostics Pack',          '19.0.0.0.0', 'TRUE'),
  ('db-prod-02', 'FINDB',   'Partitioning',              '19.0.0.0.0', 'TRUE'),
  ('db-prod-02', 'FINDB',   'Advanced Security',         '19.0.0.0.0', 'TRUE'),
  ('db-prod-02', 'FINDB',   'Diagnostics Pack',          '19.0.0.0.0', 'TRUE'),
  ('db-prod-02', 'FINDB',   'Tuning Pack',               '19.0.0.0.0', 'TRUE'),
  ('db-prod-03', 'HRDB',    'Partitioning',              '19.0.0.0.0', 'TRUE'),
  ('db-prod-03', 'HRDB',    'Diagnostics Pack',          '19.0.0.0.0', 'TRUE'),
  -- DR mirrors
  ('db-dr-01',   'PRODDB1', 'Partitioning',              '19.0.0.0.0', 'TRUE'),
  ('db-dr-01',   'PRODDB1', 'Diagnostics Pack',          '19.0.0.0.0', 'TRUE'),
  ('db-dr-01',   'PRODDB2', 'Partitioning',              '19.0.0.0.0', 'TRUE'),
  ('db-dr-02',   'FINDB',   'Partitioning',              '19.0.0.0.0', 'TRUE'),
  -- UAT / Dev — minimal options
  ('db-uat-01',  'UATDB1',  'Partitioning',              '19.0.0.0.0', 'TRUE'),
  ('db-legacy-01','LEGACYDB','Partitioning',             '12.2.0.1.0', 'TRUE'),
  ('db-legacy-01','LEGACYDB','Diagnostics Pack',         '12.2.0.1.0', 'TRUE')
) AS v(hostname, oracle_sid, option_name, option_version, status)
JOIN client_acme.oracle_servers  s ON s.hostname   = v.hostname
JOIN client_acme.oracle_instances i ON i.server_id  = s.server_id
                                    AND i.oracle_sid = v.oracle_sid;

-- =============================================================================
-- Sample discovery data — Globex Corp servers and CSIs
-- Run after sample_data.sql and 00_init.sql:
--   sudo -u postgres psql oracle_sam -f database/sample_data_globex.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Clean up so the script is re-runnable
-- ---------------------------------------------------------------------------
DELETE FROM client_globex.oracle_options
  WHERE instance_id IN (
    SELECT i.instance_id FROM client_globex.oracle_instances i
    JOIN client_globex.oracle_servers s ON s.server_id = i.server_id
    WHERE s.hostname IN (
      'gbx-prod-01','gbx-prod-02','gbx-prod-03',
      'gbx-dr-01',
      'gbx-uat-01','gbx-uat-02',
      'gbx-dev-01',
      'gbx-analytics-01','gbx-security-01'
    )
  );
DELETE FROM client_globex.oracle_instances
  WHERE server_id IN (
    SELECT server_id FROM client_globex.oracle_servers
    WHERE hostname IN (
      'gbx-prod-01','gbx-prod-02','gbx-prod-03',
      'gbx-dr-01',
      'gbx-uat-01','gbx-uat-02',
      'gbx-dev-01',
      'gbx-analytics-01','gbx-security-01'
    )
  );
DELETE FROM client_globex.oracle_processors
  WHERE server_id IN (
    SELECT server_id FROM client_globex.oracle_servers
    WHERE hostname IN (
      'gbx-prod-01','gbx-prod-02','gbx-prod-03',
      'gbx-dr-01',
      'gbx-uat-01','gbx-uat-02',
      'gbx-dev-01',
      'gbx-analytics-01','gbx-security-01'
    )
  );
DELETE FROM client_globex.oracle_servers
  WHERE hostname IN (
    'gbx-prod-01','gbx-prod-02','gbx-prod-03',
    'gbx-dr-01',
    'gbx-uat-01','gbx-uat-02',
    'gbx-dev-01',
    'gbx-analytics-01','gbx-security-01'
  );

-- ---------------------------------------------------------------------------
-- 1. Servers
-- ---------------------------------------------------------------------------
INSERT INTO client_globex.oracle_servers
  (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
   environment, criticality, total_ram_mb, datacenter, is_active, last_seen)
VALUES
  -- Production EE physical
  ('gbx-prod-01',     'gbx-prod-01.globex.internal',     '10.1.1.11', 'Linux', 'Red Hat Enterprise Linux', '8.9',  'production',  'HIGH',   131072, 'NYC-DC1', TRUE, NOW()),
  ('gbx-prod-02',     'gbx-prod-02.globex.internal',     '10.1.1.12', 'Linux', 'Red Hat Enterprise Linux', '8.9',  'production',  'HIGH',   131072, 'NYC-DC1', TRUE, NOW()),
  -- Production EE VMware
  ('gbx-prod-03',     'gbx-prod-03.globex.internal',     '10.1.1.13', 'Linux', 'Oracle Linux',             '8.8',  'production',  'MEDIUM',  65536, 'NYC-DC1', TRUE, NOW()),
  -- DR physical
  ('gbx-dr-01',       'gbx-dr-01.globex.internal',       '10.1.2.11', 'Linux', 'Red Hat Enterprise Linux', '8.9',  'dr',          'HIGH',   131072, 'CHI-DC2', TRUE, NOW()),
  -- UAT — one EE, one SE2
  ('gbx-uat-01',      'gbx-uat-01.globex.internal',      '10.1.3.11', 'Linux', 'Oracle Linux',             '8.8',  'test',        'MEDIUM',  32768, 'NYC-DC1', TRUE, NOW()),
  ('gbx-uat-02',      'gbx-uat-02.globex.internal',      '10.1.3.12', 'Linux', 'Oracle Linux',             '8.8',  'test',        'LOW',     16384, 'NYC-DC1', TRUE, NOW()),
  -- Dev SE2
  ('gbx-dev-01',      'gbx-dev-01.globex.internal',      '10.1.4.11', 'Linux', 'Oracle Linux',             '8.8',  'development', 'LOW',      8192, 'NYC-DC1', TRUE, NOW()),
  -- Analytics server — EE + OLAP + Diagnostics + Tuning + Data Mining
  ('gbx-analytics-01','gbx-analytics-01.globex.internal','10.1.1.21', 'Linux', 'Oracle Linux',             '8.8',  'production',  'HIGH',   262144, 'NYC-DC1', TRUE, NOW()),
  -- Security server — EE + Advanced Security + Database Vault + Label Security + Diagnostics
  ('gbx-security-01', 'gbx-security-01.globex.internal', '10.1.1.22', 'Linux', 'Red Hat Enterprise Linux', '8.9',  'production',  'HIGH',   131072, 'NYC-DC1', TRUE, NOW());

-- ---------------------------------------------------------------------------
-- 2. Processors
-- ---------------------------------------------------------------------------
INSERT INTO client_globex.oracle_processors
  (server_id, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
   threads_per_core, virt_type, is_vmware, vcpu_count)
SELECT s.server_id, v.cpu_model, 'x86_64',
       v.cpu_sockets, v.cores_per_socket, 2,
       v.virt_type::client_globex.virt_type, v.is_vmware, v.vcpu_count
FROM (VALUES
  ('gbx-prod-01',     'Intel Xeon Gold 6338',   2, 16, 'physical', FALSE, NULL),
  ('gbx-prod-02',     'Intel Xeon Gold 6338',   2, 16, 'physical', FALSE, NULL),
  ('gbx-prod-03',     'Intel Xeon Gold 6338',   2,  8, 'vmware',   TRUE,   8),
  ('gbx-dr-01',       'Intel Xeon Gold 6338',   2, 16, 'physical', FALSE, NULL),
  ('gbx-uat-01',      'Intel Xeon Silver 4314', 2,  8, 'vmware',   TRUE,   8),
  ('gbx-uat-02',      'Intel Xeon Silver 4314', 2,  4, 'vmware',   TRUE,   4),
  ('gbx-dev-01',      'Intel Xeon Silver 4214', 1,  4, 'vmware',   TRUE,   4),
  ('gbx-analytics-01','Intel Xeon Gold 6338',   2, 32, 'physical', FALSE, NULL),
  ('gbx-security-01', 'Intel Xeon Gold 6338',   2, 16, 'physical', FALSE, NULL)
) AS v(hostname, cpu_model, cpu_sockets, cores_per_socket, virt_type, is_vmware, vcpu_count)
JOIN client_globex.oracle_servers s USING (hostname);

-- ---------------------------------------------------------------------------
-- 3. Oracle Instances
-- ---------------------------------------------------------------------------
INSERT INTO client_globex.oracle_instances
  (server_id, oracle_sid, db_name, oracle_home, edition, db_version,
   platform_name, autostart, is_active)
SELECT s.server_id, v.oracle_sid, v.db_name, v.oracle_home,
       v.edition, v.db_version, 'Linux x86 64-bit', TRUE, TRUE
FROM (VALUES
  ('gbx-prod-01',     'GBXERP',   'GBXERP',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition',   '19.3.0.0.0'),
  ('gbx-prod-02',     'GBXCRM',   'GBXCRM',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition',   '19.3.0.0.0'),
  ('gbx-prod-03',     'GBXHR',    'GBXHR',    '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition',   '19.3.0.0.0'),
  ('gbx-dr-01',       'GBXERP',   'GBXERP',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition',   '19.3.0.0.0'),
  ('gbx-uat-01',      'GBXUAT',   'GBXUAT',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition',   '19.3.0.0.0'),
  ('gbx-uat-02',      'GBXUAT2',  'GBXUAT2',  '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Standard Edition 2',   '19.3.0.0.0'),
  ('gbx-dev-01',      'GBXDEV',   'GBXDEV',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Standard Edition 2',   '19.3.0.0.0'),
  ('gbx-analytics-01','GBXDWH',   'GBXDWH',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition',   '19.3.0.0.0'),
  ('gbx-security-01', 'GBXSEC',   'GBXSEC',   '/u01/app/oracle/product/19.0.0/dbhome_1', 'Oracle Database 19c Enterprise Edition',   '19.3.0.0.0')
) AS v(hostname, oracle_sid, db_name, oracle_home, edition, db_version)
JOIN client_globex.oracle_servers s USING (hostname);

-- ---------------------------------------------------------------------------
-- 4. Oracle Options
-- Licensable options per server (status='TRUE' means in use / needs licence)
--
--   gbx-prod-01 / GBXERP  — EE + Partitioning + Diagnostics + Tuning
--   gbx-prod-02 / GBXCRM  — EE + Partitioning + Diagnostics + Tuning + Advanced Compression
--   gbx-prod-03 / GBXHR   — EE + Diagnostics only (VMware, lighter options)
--   gbx-dr-01   / GBXERP  — EE + Partitioning + Diagnostics (DR — no Tuning Pack)
--   gbx-uat-01  / GBXUAT  — EE + Diagnostics only (UAT)
--   gbx-analytics-01       — EE + Partitioning + OLAP + Diagnostics + Tuning + Data Mining
--   gbx-security-01        — EE + Partitioning + Advanced Security + Database Vault +
--                            Label Security + Diagnostics
-- ---------------------------------------------------------------------------
INSERT INTO client_globex.oracle_options (instance_id, option_name, option_version, status)
SELECT i.instance_id, v.option_name, v.option_version, v.status
FROM (VALUES

  -- ── gbx-prod-01 / GBXERP (ERP — partitioning + diagnostics + tuning) ──────
  ('gbx-prod-01','GBXERP', 'Partitioning',         '19.0.0.0.0', 'TRUE'),
  ('gbx-prod-01','GBXERP', 'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('gbx-prod-01','GBXERP', 'Tuning Pack',          '19.0.0.0.0', 'TRUE'),
  ('gbx-prod-01','GBXERP', 'Advanced Security',    '19.0.0.0.0', 'FALSE'),
  ('gbx-prod-01','GBXERP', 'Advanced Compression', '19.0.0.0.0', 'FALSE'),

  -- ── gbx-prod-02 / GBXCRM (CRM — full option set) ─────────────────────────
  ('gbx-prod-02','GBXCRM', 'Partitioning',         '19.0.0.0.0', 'TRUE'),
  ('gbx-prod-02','GBXCRM', 'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('gbx-prod-02','GBXCRM', 'Tuning Pack',          '19.0.0.0.0', 'TRUE'),
  ('gbx-prod-02','GBXCRM', 'Advanced Compression', '19.0.0.0.0', 'TRUE'),
  ('gbx-prod-02','GBXCRM', 'Advanced Security',    '19.0.0.0.0', 'FALSE'),

  -- ── gbx-prod-03 / GBXHR (VMware HR — diagnostics only) ───────────────────
  ('gbx-prod-03','GBXHR',  'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('gbx-prod-03','GBXHR',  'Tuning Pack',          '19.0.0.0.0', 'FALSE'),
  ('gbx-prod-03','GBXHR',  'Partitioning',         '19.0.0.0.0', 'FALSE'),

  -- ── gbx-dr-01 / GBXERP (DR mirror — partitioning + diagnostics, no tuning) ─
  ('gbx-dr-01',  'GBXERP', 'Partitioning',         '19.0.0.0.0', 'TRUE'),
  ('gbx-dr-01',  'GBXERP', 'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('gbx-dr-01',  'GBXERP', 'Tuning Pack',          '19.0.0.0.0', 'FALSE'),

  -- ── gbx-uat-01 / GBXUAT (UAT EE — diagnostics only) ─────────────────────
  ('gbx-uat-01', 'GBXUAT', 'Diagnostics Pack',     '19.0.0.0.0', 'TRUE'),
  ('gbx-uat-01', 'GBXUAT', 'Tuning Pack',          '19.0.0.0.0', 'FALSE'),
  ('gbx-uat-01', 'GBXUAT', 'Partitioning',         '19.0.0.0.0', 'FALSE'),

  -- ── gbx-analytics-01 / GBXDWH (data warehouse — heavy analytics options) ─
  ('gbx-analytics-01','GBXDWH', 'Partitioning',    '19.0.0.0.0', 'TRUE'),
  ('gbx-analytics-01','GBXDWH', 'OLAP',            '19.0.0.0.0', 'TRUE'),
  ('gbx-analytics-01','GBXDWH', 'Diagnostics Pack','19.0.0.0.0', 'TRUE'),
  ('gbx-analytics-01','GBXDWH', 'Tuning Pack',     '19.0.0.0.0', 'TRUE'),
  ('gbx-analytics-01','GBXDWH', 'Data Mining',     '19.0.0.0.0', 'TRUE'),
  ('gbx-analytics-01','GBXDWH', 'Spatial and Graph','19.0.0.0.0','FALSE'),

  -- ── gbx-security-01 / GBXSEC (security/compliance — vault + label + adv sec) ─
  ('gbx-security-01','GBXSEC', 'Partitioning',      '19.0.0.0.0', 'TRUE'),
  ('gbx-security-01','GBXSEC', 'Advanced Security', '19.0.0.0.0', 'TRUE'),
  ('gbx-security-01','GBXSEC', 'Database Vault',    '19.0.0.0.0', 'TRUE'),
  ('gbx-security-01','GBXSEC', 'Label Security',    '19.0.0.0.0', 'TRUE'),
  ('gbx-security-01','GBXSEC', 'Diagnostics Pack',  '19.0.0.0.0', 'TRUE'),
  ('gbx-security-01','GBXSEC', 'Tuning Pack',       '19.0.0.0.0', 'FALSE')

) AS v(hostname, oracle_sid, option_name, option_version, status)
JOIN client_globex.oracle_servers   s ON s.hostname   = v.hostname
JOIN client_globex.oracle_instances i ON i.server_id  = s.server_id
                                     AND i.oracle_sid = v.oracle_sid;


-- ---------------------------------------------------------------------------
-- 5. New CSIs for Globex
-- ---------------------------------------------------------------------------

-- ---- CSI D: Globex-locked EE + Options contract ──────────────────────────
-- Covers gbx-prod-01, gbx-prod-02 and their DR — EE + Partitioning +
-- Diagnostics + Tuning + Advanced Compression
DO $$
DECLARE v_csi INTEGER;
BEGIN
  IF EXISTS (SELECT 1 FROM shared.csi_contracts WHERE vendor_reference = 'ORD-2024-GBX-01') THEN
    RAISE NOTICE 'Contract ORD-2024-GBX-01 already exists — skipping.'; RETURN;
  END IF;
  v_csi := shared.add_csi(
    p_contract_name  => 'Globex EE Production Contract 2024',
    p_csi_number     => '44444444',
    p_vendor_ref     => 'ORD-2024-GBX-01',
    p_purchase_date  => '2024-01-15',
    p_support_start  => '2024-01-15',
    p_support_expiry => '2027-01-15',
    p_currency       => 'USD',
    p_locked_to      => 'globex',
    p_notes          => 'Globex production EE pool — covers prod and DR'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Enterprise Edition',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 80,
    p_unit_price     => 47500.00,
    p_annual_support => 836000.00,
    p_notes          => 'EE base — covers prod and DR servers'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Partitioning',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 80,
    p_unit_price     => 11500.00,
    p_annual_support => 202400.00
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Diagnostics Pack',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 80,
    p_unit_price     => 7500.00,
    p_annual_support => 132000.00,
    p_notes          => 'AWR / ADDM / ASH'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Tuning Pack',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 60,
    p_unit_price     => 5000.00,
    p_annual_support => 66000.00,
    p_notes          => 'Tuning Pack — prod only, not DR'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Advanced Compression',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 32,
    p_unit_price     => 11500.00,
    p_annual_support => 80960.00,
    p_notes          => 'CRM server only'
  );
END $$;


-- ---- CSI E: Globex Analytics + Security options contract ─────────────────
-- Covers gbx-analytics-01 and gbx-security-01
DO $$
DECLARE v_csi INTEGER;
BEGIN
  IF EXISTS (SELECT 1 FROM shared.csi_contracts WHERE vendor_reference = 'ORD-2024-GBX-02') THEN
    RAISE NOTICE 'Contract ORD-2024-GBX-02 already exists — skipping.'; RETURN;
  END IF;
  v_csi := shared.add_csi(
    p_contract_name  => 'Globex Analytics & Security Options 2024',
    p_csi_number     => '55555555',
    p_vendor_ref     => 'ORD-2024-GBX-02',
    p_purchase_date  => '2024-03-01',
    p_support_start  => '2024-03-01',
    p_support_expiry => '2027-03-01',
    p_currency       => 'USD',
    p_locked_to      => 'globex',
    p_notes          => 'Analytics DWH and security/compliance server options'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Enterprise Edition',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 96,
    p_unit_price     => 47500.00,
    p_annual_support => 1003200.00,
    p_notes          => 'EE base for analytics and security servers'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Partitioning',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 96,
    p_unit_price     => 11500.00,
    p_annual_support => 243072.00
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle OLAP',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 64,
    p_unit_price     => 23000.00,
    p_annual_support => 323840.00,
    p_notes          => 'Analytics server only'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Diagnostics Pack',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 96,
    p_unit_price     => 7500.00,
    p_annual_support => 158400.00
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Tuning Pack',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 64,
    p_unit_price     => 5000.00,
    p_annual_support => 70400.00,
    p_notes          => 'Analytics server only'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Data Mining',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 64,
    p_unit_price     => 23000.00,
    p_annual_support => 323840.00,
    p_notes          => 'In-database ML — analytics server'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Advanced Security',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 32,
    p_unit_price     => 15000.00,
    p_annual_support => 105600.00,
    p_notes          => 'Security server — TDE and network encryption'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Vault',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 32,
    p_unit_price     => 23000.00,
    p_annual_support => 161920.00,
    p_notes          => 'Security server — privileged user controls'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Label Security',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 32,
    p_unit_price     => 11500.00,
    p_annual_support => 80960.00,
    p_notes          => 'Security server — row-level security'
  );
END $$;

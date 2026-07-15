-- ---------------------------------------------------------------------------
-- sample_data_nup.sql
-- Named User Plus (NUP) test data for client_acme
--
-- Adds three NUP-licensed servers:
--   db-nup-ee-01   EE on physical 2-socket/8-core box
--                  NUP minimum = 8 cores × 1.0 core-factor × 25 = 200
--                  15 active users  → licences_required = 200 (floor wins)
--
--   db-nup-ee-02   EE on physical 2-socket/8-core box
--                  NUP minimum = 200
--                  350 active users → licences_required = 350 (users win)
--
--   db-nup-se2-01  SE2 on physical 1-socket/4-core box
--                  NUP minimum = min(1 socket, 2) × 10 = 10
--                  8 active users   → licences_required = 10 (floor wins)
--
-- Also adds a NUP CSI contract (ORD-2025-ACME-NUP) locked to acme and
-- maps each NUP server to it.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1.  NUP servers
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_servers
  (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
   environment, criticality, total_ram_mb, datacenter, is_active, last_seen,
   licence_metric_override)
VALUES
  ('db-nup-ee-01',  'db-nup-ee-01.acme.internal',  '10.0.7.11',
   'Linux', 'Oracle Linux', '8.8', 'production', 'HIGH', 65536, 'LON-DC1',
   TRUE, NOW(), 'named_user_plus'),

  ('db-nup-ee-02',  'db-nup-ee-02.acme.internal',  '10.0.7.12',
   'Linux', 'Oracle Linux', '8.8', 'production', 'HIGH', 65536, 'LON-DC1',
   TRUE, NOW(), 'named_user_plus'),

  ('db-nup-se2-01', 'db-nup-se2-01.acme.internal', '10.0.7.13',
   'Linux', 'Red Hat Enterprise Linux', '8.9', 'production', 'MEDIUM', 32768, 'LON-DC1',
   TRUE, NOW(), 'named_user_plus');


-- ---------------------------------------------------------------------------
-- 2.  Processors
--     EE servers:   2-socket, 8 cores/socket, physical  → core_factor 1.0
--     SE2 server:   1-socket, 4 cores/socket, physical  → SE2 rules apply
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_processors
  (server_id, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
   threads_per_core, virt_type, is_vmware, vcpu_count)
SELECT s.server_id, v.cpu_model, 'x86_64',
       v.cpu_sockets, v.cores_per_socket, 2,
       v.virt_type::client_acme.virt_type, FALSE, NULL
FROM (VALUES
  ('db-nup-ee-01',  'Intel Xeon Gold 6338', 2, 8, 'physical'),
  ('db-nup-ee-02',  'Intel Xeon Gold 6338', 2, 8, 'physical'),
  ('db-nup-se2-01', 'Intel Xeon Silver 4214', 1, 4, 'physical')
) AS v(hostname, cpu_model, cpu_sockets, cores_per_socket, virt_type)
JOIN client_acme.oracle_servers s USING (hostname);


-- ---------------------------------------------------------------------------
-- 3.  Oracle Instances
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_instances
  (server_id, oracle_sid, db_name, oracle_home, edition, db_version,
   platform_name, autostart, is_active)
SELECT s.server_id, v.oracle_sid, v.db_name, v.oracle_home,
       v.edition, '19.3.0.0.0', 'Linux x86 64-bit', TRUE, TRUE
FROM (VALUES
  ('db-nup-ee-01',  'NUPDB1', 'NUPDB1',
   '/u01/app/oracle/product/19.0.0/dbhome_1',
   'Oracle Database 19c Enterprise Edition'),

  ('db-nup-ee-02',  'NUPDB2', 'NUPDB2',
   '/u01/app/oracle/product/19.0.0/dbhome_1',
   'Oracle Database 19c Enterprise Edition'),

  ('db-nup-se2-01', 'NUPSE2', 'NUPSE2',
   '/u01/app/oracle/product/19.0.0/dbhome_1',
   'Oracle Database 19c Standard Edition 2')
) AS v(hostname, oracle_sid, db_name, oracle_home, edition)
JOIN client_acme.oracle_servers s USING (hostname)
ON CONFLICT (server_id, oracle_sid) DO NOTHING;


-- ---------------------------------------------------------------------------
-- 4.  NUP user counts
--     Inserted for each instance; the view picks the latest snapshot.
--
--     db-nup-ee-01:  15 active  — floor (200) wins
--     db-nup-ee-02: 350 active  — users (350) win over floor (200)
--     db-nup-se2-01:  8 active  — floor (10) wins
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_nup_users
  (instance_id, snapshot_date, active_user_count, total_user_count,
   locked_user_count, sample_user_list, discovery_run_id)
SELECT i.instance_id, v.snap_date, v.active, v.total, v.locked,
       v.users, v.run_id
FROM (VALUES
  ('db-nup-ee-01',  'NUPDB1', CURRENT_DATE,  15,  18,  3,
   ARRAY['alice','bob','carol','dave','eve','frank','grace','henry',
         'iris','jack','kate','leo','mia','noah','olivia'],
   'sample-nup-run-001'),

  ('db-nup-ee-02',  'NUPDB2', CURRENT_DATE, 350, 380, 30, NULL,
   'sample-nup-run-001'),

  ('db-nup-se2-01', 'NUPSE2', CURRENT_DATE,   8,  10,  2,
   ARRAY['alice','bob','carol','dave','eve','frank','grace','henry'],
   'sample-nup-run-001')
) AS v(hostname, oracle_sid, snap_date, active, total, locked, users, run_id)
JOIN client_acme.oracle_servers s USING (hostname)
JOIN client_acme.oracle_instances i
  ON i.server_id = s.server_id AND i.oracle_sid = v.oracle_sid;


-- ---------------------------------------------------------------------------
-- 5.  CSI contract: NUP licences
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_csi INTEGER;
BEGIN
  IF EXISTS (SELECT 1 FROM shared.csi_contracts WHERE vendor_reference = 'ORD-2025-ACME-NUP') THEN
    RAISE NOTICE 'Contract ORD-2025-ACME-NUP already exists — skipping.'; RETURN;
  END IF;

  v_csi := shared.add_csi(
    p_contract_name  => 'Acme NUP Licence Contract 2025',
    p_csi_number     => '88888888',
    p_vendor_ref     => 'ORD-2025-ACME-NUP',
    p_purchase_date  => '2025-01-01',
    p_support_start  => '2025-01-01',
    p_support_expiry => '2028-01-01',
    p_currency       => 'USD',
    p_locked_to      => 'acme',
    p_notes          => 'Named User Plus licences for low-user-count production databases'
  );

  -- EE NUP: 600 licences covers both EE NUP servers
  -- db-nup-ee-01 needs 200 (floor), db-nup-ee-02 needs 350 → total 550
  -- Purchasing 600 leaves a small buffer
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Enterprise Edition',
    p_product_family => 'oracle_database',
    p_metric         => 'named_user_plus',
    p_quantity       => 600,
    p_unit_price     => 950.00,
    p_annual_support => 132600.00,
    p_notes          => 'EE NUP — covers db-nup-ee-01 (200 req) and db-nup-ee-02 (350 req)'
  );

  -- SE2 NUP: 10 licences — exactly meets the floor for db-nup-se2-01
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Standard Edition 2',
    p_product_family => 'oracle_database',
    p_metric         => 'named_user_plus',
    p_quantity       => 10,
    p_unit_price     => 350.00,
    p_annual_support => 770.00,
    p_notes          => 'SE2 NUP — exactly meets 10-NUP-per-socket floor for db-nup-se2-01'
  );
END $$;


-- ---------------------------------------------------------------------------
-- 6.  Map NUP servers to the CSI
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.server_csi_map
  (server_id, csi_id, line_id, product_family, product_detail,
   licences_consumed, effective_date, notes, assigned_by)
SELECT
  s.server_id,
  c.csi_id,
  l.line_id,
  'oracle_database',
  v.product_detail,
  v.licences_consumed,
  CURRENT_DATE,
  v.notes,
  'sample-data-loader'
FROM (VALUES
  -- db-nup-ee-01: 200 NUP (floor wins over 15 active users)
  ('db-nup-ee-01', 'Oracle Database Enterprise Edition',
   200::NUMERIC, 'NUP floor — 2 sockets × 8 cores × 1.0 CF × 25 = 200'),

  -- db-nup-ee-02: 350 NUP (active users win over 200 floor)
  ('db-nup-ee-02', 'Oracle Database Enterprise Edition',
   350::NUMERIC, 'User count — 350 active NUP users exceeds 200 floor'),

  -- db-nup-se2-01: 10 NUP (floor wins over 8 active users)
  ('db-nup-se2-01', 'Oracle Database Standard Edition 2',
   10::NUMERIC, 'NUP floor — min(1 socket,2) × 10 = 10')
) AS v(hostname, product_detail, licences_consumed, notes)
JOIN client_acme.oracle_servers s USING (hostname)
JOIN shared.csi_contracts c ON c.vendor_reference = 'ORD-2025-ACME-NUP'
JOIN shared.license_entitlement_lines l
  ON l.csi_id = c.csi_id
  AND l.product_detail = v.product_detail
ON CONFLICT DO NOTHING;

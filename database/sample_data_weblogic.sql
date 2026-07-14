-- =============================================================================
-- Sample WebLogic discovery data + mixed DB/WLS CSIs
-- Covers: Acme Corp (client_acme) and Globex Corp (client_globex)
--
-- Run after sample_data.sql and sample_data_globex.sql:
--   sudo -u postgres psql oracle_sam -f database/sample_data_weblogic.sql
-- =============================================================================


-- ---------------------------------------------------------------------------
-- Clean up so script is re-runnable
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_sid INTEGER;
BEGIN
  -- Acme WLS servers
  FOR v_sid IN
    SELECT server_id FROM client_acme.oracle_servers
    WHERE hostname IN (
      'wls-prod-01','wls-prod-02','wls-prod-03',
      'wls-dr-01','wls-uat-01','wls-dev-01'
    )
  LOOP
    DELETE FROM client_acme.wls_installed_products WHERE domain_id IN
      (SELECT domain_id FROM client_acme.wls_domains WHERE server_id = v_sid);
    DELETE FROM client_acme.wls_managed_servers WHERE domain_id IN
      (SELECT domain_id FROM client_acme.wls_domains WHERE server_id = v_sid);
    DELETE FROM client_acme.wls_domains WHERE server_id = v_sid;
    DELETE FROM client_acme.oracle_processors WHERE server_id = v_sid;
  END LOOP;
  DELETE FROM client_acme.oracle_servers WHERE hostname IN (
    'wls-prod-01','wls-prod-02','wls-prod-03',
    'wls-dr-01','wls-uat-01','wls-dev-01'
  );

  -- Globex WLS servers
  FOR v_sid IN
    SELECT server_id FROM client_globex.oracle_servers
    WHERE hostname IN (
      'gbx-wls-prod-01','gbx-wls-prod-02',
      'gbx-wls-dr-01','gbx-wls-uat-01'
    )
  LOOP
    DELETE FROM client_globex.wls_installed_products WHERE domain_id IN
      (SELECT domain_id FROM client_globex.wls_domains WHERE server_id = v_sid);
    DELETE FROM client_globex.wls_managed_servers WHERE domain_id IN
      (SELECT domain_id FROM client_globex.wls_domains WHERE server_id = v_sid);
    DELETE FROM client_globex.wls_domains WHERE server_id = v_sid;
    DELETE FROM client_globex.oracle_processors WHERE server_id = v_sid;
  END LOOP;
  DELETE FROM client_globex.oracle_servers WHERE hostname IN (
    'gbx-wls-prod-01','gbx-wls-prod-02',
    'gbx-wls-dr-01','gbx-wls-uat-01'
  );
END $$;


-- ===========================================================================
-- ACME CORP — WebLogic Servers
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Servers
-- ---------------------------------------------------------------------------
INSERT INTO client_acme.oracle_servers
  (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
   environment, criticality, total_ram_mb, datacenter, is_active, last_seen)
VALUES
  -- Production cluster: 2-node WLS cluster hosting ERP front-end + SOA
  ('wls-prod-01', 'wls-prod-01.acme.internal', '10.0.1.31', 'Linux', 'Oracle Linux', '8.8',
   'production', 'HIGH', 65536, 'LON-DC1', TRUE, NOW()),
  ('wls-prod-02', 'wls-prod-02.acme.internal', '10.0.1.32', 'Linux', 'Oracle Linux', '8.8',
   'production', 'HIGH', 65536, 'LON-DC1', TRUE, NOW()),
  -- Production standalone: API Gateway / OSB node
  ('wls-prod-03', 'wls-prod-03.acme.internal', '10.0.1.33', 'Linux', 'Red Hat Enterprise Linux', '8.9',
   'production', 'MEDIUM', 32768, 'LON-DC1', TRUE, NOW()),
  -- DR: single-node cold standby for prod-01 domain
  ('wls-dr-01',   'wls-dr-01.acme.internal',   '10.0.2.31', 'Linux', 'Oracle Linux', '8.8',
   'dr',          'HIGH',   65536, 'MAN-DC2', TRUE, NOW()),
  -- UAT
  ('wls-uat-01',  'wls-uat-01.acme.internal',  '10.0.3.31', 'Linux', 'Oracle Linux', '8.8',
   'test',        'MEDIUM', 32768, 'LON-DC1', TRUE, NOW()),
  -- Dev
  ('wls-dev-01',  'wls-dev-01.acme.internal',  '10.0.4.31', 'Linux', 'Oracle Linux', '8.8',
   'development', 'LOW',    16384, 'LON-DC1', TRUE, NOW());

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
  ('wls-prod-01', 'Intel Xeon Gold 6338', 2, 16, 'vmware',   TRUE,  16),
  ('wls-prod-02', 'Intel Xeon Gold 6338', 2, 16, 'vmware',   TRUE,  16),
  ('wls-prod-03', 'Intel Xeon Gold 6338', 2,  8, 'vmware',   TRUE,   8),
  ('wls-dr-01',   'Intel Xeon Gold 6338', 2, 16, 'vmware',   TRUE,  16),
  ('wls-uat-01',  'Intel Xeon Silver 4314', 2, 8, 'vmware',  TRUE,   8),
  ('wls-dev-01',  'Intel Xeon Silver 4214', 1, 4, 'vmware',  TRUE,   4)
) AS v(hostname, cpu_model, cpu_sockets, cores_per_socket, virt_type, is_vmware, vcpu_count)
JOIN client_acme.oracle_servers s USING (hostname);

-- ---------------------------------------------------------------------------
-- 3. WLS Domains
-- ---------------------------------------------------------------------------

-- wls-prod-01: ERP SOA domain (cluster node 1)
WITH ins AS (
  INSERT INTO client_acme.wls_domains
    (server_id, domain_name, domain_home, wls_version, wls_edition,
     admin_server_host, admin_server_port, is_active, last_seen, discovery_run_id)
  SELECT s.server_id,
    'acme_erp_soa_domain',
    '/u01/app/oracle/middleware/user_projects/domains/acme_erp_soa_domain',
    '14.1.1.0.0', 'WebLogic Server Enterprise Edition',
    'wls-prod-01.acme.internal', 7001, TRUE, NOW(), 'sample-run-001'
  FROM client_acme.oracle_servers s WHERE s.hostname = 'wls-prod-01'
  ON CONFLICT (server_id, domain_name) DO UPDATE SET
    wls_version = EXCLUDED.wls_version, wls_edition = EXCLUDED.wls_edition,
    last_seen = NOW()
  RETURNING domain_id
),
ms AS (
  INSERT INTO client_acme.wls_managed_servers
    (domain_id, server_id, managed_server_name, listen_port, ssl_port,
     cluster_name, machine_name, state, last_seen, discovery_run_id)
  SELECT i.domain_id, s.server_id, v.ms_name, v.port, v.ssl, v.cluster, v.machine, 'RUNNING', NOW(), 'sample-run-001'
  FROM ins i, client_acme.oracle_servers s,
  (VALUES
    ('soa_server1', 8001, 8002, 'SOA_Cluster', 'machine-wls-prod-01'),
    ('osb_server1', 9001, 9002, 'OSB_Cluster', 'machine-wls-prod-01')
  ) AS v(ms_name, port, ssl, cluster, machine)
  WHERE s.hostname = 'wls-prod-01'
)
INSERT INTO client_acme.wls_installed_products
  (domain_id, product_name, product_version, home_path, discovery_run_id)
SELECT i.domain_id, v.name, v.ver, v.home, 'sample-run-001'
FROM ins i,
(VALUES
  ('Oracle SOA Suite',                    '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle Service Bus',                  '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle WebLogic Server',              '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle JRF',                          '14.1.1.0.0', '/u01/app/oracle/middleware')
) AS v(name, ver, home);


-- wls-prod-02: same ERP SOA domain (cluster node 2, admin hosted on prod-01)
WITH ins AS (
  INSERT INTO client_acme.wls_domains
    (server_id, domain_name, domain_home, wls_version, wls_edition,
     admin_server_host, admin_server_port, is_active, last_seen, discovery_run_id)
  SELECT s.server_id,
    'acme_erp_soa_domain',
    '/u01/app/oracle/middleware/user_projects/domains/acme_erp_soa_domain',
    '14.1.1.0.0', 'WebLogic Server Enterprise Edition',
    'wls-prod-01.acme.internal', 7001, TRUE, NOW(), 'sample-run-001'
  FROM client_acme.oracle_servers s WHERE s.hostname = 'wls-prod-02'
  ON CONFLICT (server_id, domain_name) DO UPDATE SET
    wls_version = EXCLUDED.wls_version, wls_edition = EXCLUDED.wls_edition,
    last_seen = NOW()
  RETURNING domain_id
),
ms AS (
  INSERT INTO client_acme.wls_managed_servers
    (domain_id, server_id, managed_server_name, listen_port, ssl_port,
     cluster_name, machine_name, state, last_seen, discovery_run_id)
  SELECT i.domain_id, s.server_id, v.ms_name, v.port, v.ssl, v.cluster, v.machine, 'RUNNING', NOW(), 'sample-run-001'
  FROM ins i, client_acme.oracle_servers s,
  (VALUES
    ('soa_server2', 8001, 8002, 'SOA_Cluster', 'machine-wls-prod-02'),
    ('osb_server2', 9001, 9002, 'OSB_Cluster', 'machine-wls-prod-02')
  ) AS v(ms_name, port, ssl, cluster, machine)
  WHERE s.hostname = 'wls-prod-02'
)
INSERT INTO client_acme.wls_installed_products
  (domain_id, product_name, product_version, home_path, discovery_run_id)
SELECT i.domain_id, v.name, v.ver, v.home, 'sample-run-001'
FROM ins i,
(VALUES
  ('Oracle SOA Suite',       '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle Service Bus',     '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle WebLogic Server', '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle JRF',             '14.1.1.0.0', '/u01/app/oracle/middleware')
) AS v(name, ver, home);


-- wls-prod-03: standalone API Gateway / OSB domain
WITH ins AS (
  INSERT INTO client_acme.wls_domains
    (server_id, domain_name, domain_home, wls_version, wls_edition,
     admin_server_host, admin_server_port, is_active, last_seen, discovery_run_id)
  SELECT s.server_id,
    'acme_osb_gateway_domain',
    '/u01/app/oracle/middleware/user_projects/domains/acme_osb_gateway_domain',
    '14.1.1.0.0', 'WebLogic Server Standard Edition',
    'wls-prod-03.acme.internal', 7001, TRUE, NOW(), 'sample-run-001'
  FROM client_acme.oracle_servers s WHERE s.hostname = 'wls-prod-03'
  ON CONFLICT (server_id, domain_name) DO UPDATE SET
    wls_version = EXCLUDED.wls_version, wls_edition = EXCLUDED.wls_edition,
    last_seen = NOW()
  RETURNING domain_id
),
ms AS (
  INSERT INTO client_acme.wls_managed_servers
    (domain_id, server_id, managed_server_name, listen_port, ssl_port,
     cluster_name, machine_name, state, last_seen, discovery_run_id)
  SELECT i.domain_id, s.server_id, v.ms_name, v.port, v.ssl, v.cluster, v.machine, 'RUNNING', NOW(), 'sample-run-001'
  FROM ins i, client_acme.oracle_servers s,
  (VALUES
    ('osb_gw_server1', 8001, 8002, NULL, 'machine-wls-prod-03')
  ) AS v(ms_name, port, ssl, cluster, machine)
  WHERE s.hostname = 'wls-prod-03'
)
INSERT INTO client_acme.wls_installed_products
  (domain_id, product_name, product_version, home_path, discovery_run_id)
SELECT i.domain_id, v.name, v.ver, v.home, 'sample-run-001'
FROM ins i,
(VALUES
  ('Oracle Service Bus',     '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle WebLogic Server', '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle JRF',             '14.1.1.0.0', '/u01/app/oracle/middleware')
) AS v(name, ver, home);


-- wls-dr-01: DR cold standby for the ERP SOA domain
WITH ins AS (
  INSERT INTO client_acme.wls_domains
    (server_id, domain_name, domain_home, wls_version, wls_edition,
     admin_server_host, admin_server_port, is_active, last_seen, discovery_run_id)
  SELECT s.server_id,
    'acme_erp_soa_domain',
    '/u01/app/oracle/middleware/user_projects/domains/acme_erp_soa_domain',
    '14.1.1.0.0', 'WebLogic Server Enterprise Edition',
    'wls-dr-01.acme.internal', 7001, TRUE, NOW(), 'sample-run-001'
  FROM client_acme.oracle_servers s WHERE s.hostname = 'wls-dr-01'
  ON CONFLICT (server_id, domain_name) DO UPDATE SET
    wls_version = EXCLUDED.wls_version, wls_edition = EXCLUDED.wls_edition,
    last_seen = NOW()
  RETURNING domain_id
),
ms AS (
  INSERT INTO client_acme.wls_managed_servers
    (domain_id, server_id, managed_server_name, listen_port, ssl_port,
     cluster_name, machine_name, state, last_seen, discovery_run_id)
  SELECT i.domain_id, s.server_id, v.ms_name, v.port, v.ssl, v.cluster, v.machine, 'SHUTDOWN', NOW(), 'sample-run-001'
  FROM ins i, client_acme.oracle_servers s,
  (VALUES
    ('soa_server_dr', 8001, 8002, 'SOA_Cluster', 'machine-wls-dr-01'),
    ('osb_server_dr', 9001, 9002, 'OSB_Cluster', 'machine-wls-dr-01')
  ) AS v(ms_name, port, ssl, cluster, machine)
  WHERE s.hostname = 'wls-dr-01'
)
INSERT INTO client_acme.wls_installed_products
  (domain_id, product_name, product_version, home_path, discovery_run_id)
SELECT i.domain_id, v.name, v.ver, v.home, 'sample-run-001'
FROM ins i,
(VALUES
  ('Oracle SOA Suite',       '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle Service Bus',     '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle WebLogic Server', '14.1.1.0.0', '/u01/app/oracle/middleware'),
  ('Oracle JRF',             '14.1.1.0.0', '/u01/app/oracle/middleware')
) AS v(name, ver, home);


-- wls-uat-01: UAT domain (SE-level — WLS Standard Edition)
WITH ins AS (
  INSERT INTO client_acme.wls_domains
    (server_id, domain_name, domain_home, wls_version, wls_edition,
     admin_server_host, admin_server_port, is_active, last_seen, discovery_run_id)
  SELECT s.server_id,
    'acme_uat_domain',
    '/u01/app/oracle/middleware/user_projects/domains/acme_uat_domain',
    '14.1.1.0.0', 'WebLogic Server Standard Edition',
    'wls-uat-01.acme.internal', 7001, TRUE, NOW(), 'sample-run-001'
  FROM client_acme.oracle_servers s WHERE s.hostname = 'wls-uat-01'
  ON CONFLICT (server_id, domain_name) DO UPDATE SET
    wls_version = EXCLUDED.wls_version, wls_edition = EXCLUDED.wls_edition,
    last_seen = NOW()
  RETURNING domain_id
),
ms AS (
  INSERT INTO client_acme.wls_managed_servers
    (domain_id, server_id, managed_server_name, listen_port, ssl_port,
     cluster_name, machine_name, state, last_seen, discovery_run_id)
  SELECT i.domain_id, s.server_id, v.ms_name, v.port, v.ssl, v.cluster, v.machine, 'RUNNING', NOW(), 'sample-run-001'
  FROM ins i, client_acme.oracle_servers s,
  (VALUES
    ('uat_server1', 8001, 8002, NULL, 'machine-wls-uat-01')
  ) AS v(ms_name, port, ssl, cluster, machine)
  WHERE s.hostname = 'wls-uat-01'
)
INSERT INTO client_acme.wls_installed_products
  (domain_id, product_name, product_version, home_path, discovery_run_id)
SELECT i.domain_id, v.name, v.ver, v.home, 'sample-run-001'
FROM ins i,
(VALUES
  ('Oracle WebLogic Server', '14.1.1.0.0', '/u01/app/oracle/middleware')
) AS v(name, ver, home);


-- wls-dev-01: Dev domain (plain WLS, no middleware products)
WITH ins AS (
  INSERT INTO client_acme.wls_domains
    (server_id, domain_name, domain_home, wls_version, wls_edition,
     admin_server_host, admin_server_port, is_active, last_seen, discovery_run_id)
  SELECT s.server_id,
    'acme_dev_domain',
    '/u01/app/oracle/middleware/user_projects/domains/acme_dev_domain',
    '14.1.1.0.0', 'WebLogic Server Standard Edition',
    'wls-dev-01.acme.internal', 7001, TRUE, NOW(), 'sample-run-001'
  FROM client_acme.oracle_servers s WHERE s.hostname = 'wls-dev-01'
  ON CONFLICT (server_id, domain_name) DO UPDATE SET
    wls_version = EXCLUDED.wls_version, wls_edition = EXCLUDED.wls_edition,
    last_seen = NOW()
  RETURNING domain_id
)
INSERT INTO client_acme.wls_installed_products
  (domain_id, product_name, product_version, home_path, discovery_run_id)
SELECT i.domain_id, v.name, v.ver, v.home, 'sample-run-001'
FROM ins i,
(VALUES
  ('Oracle WebLogic Server', '14.1.1.0.0', '/u01/app/oracle/middleware')
) AS v(name, ver, home);


-- ===========================================================================
-- GLOBEX CORP — WebLogic Servers
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 4. Servers
-- ---------------------------------------------------------------------------
INSERT INTO client_globex.oracle_servers
  (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
   environment, criticality, total_ram_mb, datacenter, is_active, last_seen)
VALUES
  -- Production cluster: 2-node WLS Suite hosting OAM + Identity
  ('gbx-wls-prod-01', 'gbx-wls-prod-01.globex.internal', '10.1.1.31', 'Linux', 'Red Hat Enterprise Linux', '8.9',
   'production', 'HIGH', 131072, 'NYC-DC1', TRUE, NOW()),
  ('gbx-wls-prod-02', 'gbx-wls-prod-02.globex.internal', '10.1.1.32', 'Linux', 'Red Hat Enterprise Linux', '8.9',
   'production', 'HIGH', 131072, 'NYC-DC1', TRUE, NOW()),
  -- DR: single-node
  ('gbx-wls-dr-01',   'gbx-wls-dr-01.globex.internal',   '10.1.2.31', 'Linux', 'Red Hat Enterprise Linux', '8.9',
   'dr',          'HIGH',   131072, 'CHI-DC2', TRUE, NOW()),
  -- UAT
  ('gbx-wls-uat-01',  'gbx-wls-uat-01.globex.internal',  '10.1.3.31', 'Linux', 'Oracle Linux', '8.8',
   'test',        'MEDIUM',  32768, 'NYC-DC1', TRUE, NOW());

-- ---------------------------------------------------------------------------
-- 5. Processors
-- ---------------------------------------------------------------------------
INSERT INTO client_globex.oracle_processors
  (server_id, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
   threads_per_core, virt_type, is_vmware, vcpu_count)
SELECT s.server_id, v.cpu_model, 'x86_64',
       v.cpu_sockets, v.cores_per_socket, 2,
       v.virt_type::client_globex.virt_type, v.is_vmware, v.vcpu_count
FROM (VALUES
  ('gbx-wls-prod-01', 'Intel Xeon Gold 6338', 2, 32, 'physical', FALSE, NULL),
  ('gbx-wls-prod-02', 'Intel Xeon Gold 6338', 2, 32, 'physical', FALSE, NULL),
  ('gbx-wls-dr-01',   'Intel Xeon Gold 6338', 2, 32, 'physical', FALSE, NULL),
  ('gbx-wls-uat-01',  'Intel Xeon Silver 4314', 2, 8, 'vmware',  TRUE,   8)
) AS v(hostname, cpu_model, cpu_sockets, cores_per_socket, virt_type, is_vmware, vcpu_count)
JOIN client_globex.oracle_servers s USING (hostname);

-- ---------------------------------------------------------------------------
-- 6. WLS Domains
-- ---------------------------------------------------------------------------

-- gbx-wls-prod-01: Identity & Access Management (OAM) domain node 1
WITH ins AS (
  INSERT INTO client_globex.wls_domains
    (server_id, domain_name, domain_home, wls_version, wls_edition,
     admin_server_host, admin_server_port, is_active, last_seen, discovery_run_id)
  SELECT s.server_id,
    'globex_iam_domain',
    '/u01/app/oracle/middleware/user_projects/domains/globex_iam_domain',
    '12.2.1.4.0', 'WebLogic Suite',
    'gbx-wls-prod-01.globex.internal', 7001, TRUE, NOW(), 'sample-run-001'
  FROM client_globex.oracle_servers s WHERE s.hostname = 'gbx-wls-prod-01'
  ON CONFLICT (server_id, domain_name) DO UPDATE SET
    wls_version = EXCLUDED.wls_version, wls_edition = EXCLUDED.wls_edition,
    last_seen = NOW()
  RETURNING domain_id
),
ms AS (
  INSERT INTO client_globex.wls_managed_servers
    (domain_id, server_id, managed_server_name, listen_port, ssl_port,
     cluster_name, machine_name, state, last_seen, discovery_run_id)
  SELECT i.domain_id, s.server_id, v.ms_name, v.port, v.ssl, v.cluster, v.machine, 'RUNNING', NOW(), 'sample-run-001'
  FROM ins i, client_globex.oracle_servers s,
  (VALUES
    ('oam_server1',  14100, 14101, 'oam_cluster',  'machine-gbx-wls-prod-01'),
    ('oud_server1',  3060,  3131,  'oud_cluster',  'machine-gbx-wls-prod-01'),
    ('oig_server1',  14000, 14001, 'oig_cluster',  'machine-gbx-wls-prod-01')
  ) AS v(ms_name, port, ssl, cluster, machine)
  WHERE s.hostname = 'gbx-wls-prod-01'
)
INSERT INTO client_globex.wls_installed_products
  (domain_id, product_name, product_version, home_path, discovery_run_id)
SELECT i.domain_id, v.name, v.ver, v.home, 'sample-run-001'
FROM ins i,
(VALUES
  ('Oracle Access Manager',             '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle Identity Governance',        '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle Unified Directory',          '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle Coherence',                  '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle WebLogic Server',            '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle JRF',                        '12.2.1.4.0', '/u01/app/oracle/middleware')
) AS v(name, ver, home);


-- gbx-wls-prod-02: IAM domain node 2
WITH ins AS (
  INSERT INTO client_globex.wls_domains
    (server_id, domain_name, domain_home, wls_version, wls_edition,
     admin_server_host, admin_server_port, is_active, last_seen, discovery_run_id)
  SELECT s.server_id,
    'globex_iam_domain',
    '/u01/app/oracle/middleware/user_projects/domains/globex_iam_domain',
    '12.2.1.4.0', 'WebLogic Suite',
    'gbx-wls-prod-01.globex.internal', 7001, TRUE, NOW(), 'sample-run-001'
  FROM client_globex.oracle_servers s WHERE s.hostname = 'gbx-wls-prod-02'
  ON CONFLICT (server_id, domain_name) DO UPDATE SET
    wls_version = EXCLUDED.wls_version, wls_edition = EXCLUDED.wls_edition,
    last_seen = NOW()
  RETURNING domain_id
),
ms AS (
  INSERT INTO client_globex.wls_managed_servers
    (domain_id, server_id, managed_server_name, listen_port, ssl_port,
     cluster_name, machine_name, state, last_seen, discovery_run_id)
  SELECT i.domain_id, s.server_id, v.ms_name, v.port, v.ssl, v.cluster, v.machine, 'RUNNING', NOW(), 'sample-run-001'
  FROM ins i, client_globex.oracle_servers s,
  (VALUES
    ('oam_server2',  14100, 14101, 'oam_cluster', 'machine-gbx-wls-prod-02'),
    ('oud_server2',  3060,  3131,  'oud_cluster', 'machine-gbx-wls-prod-02'),
    ('oig_server2',  14000, 14001, 'oig_cluster', 'machine-gbx-wls-prod-02')
  ) AS v(ms_name, port, ssl, cluster, machine)
  WHERE s.hostname = 'gbx-wls-prod-02'
)
INSERT INTO client_globex.wls_installed_products
  (domain_id, product_name, product_version, home_path, discovery_run_id)
SELECT i.domain_id, v.name, v.ver, v.home, 'sample-run-001'
FROM ins i,
(VALUES
  ('Oracle Access Manager',      '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle Identity Governance', '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle Unified Directory',   '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle Coherence',           '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle WebLogic Server',     '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle JRF',                 '12.2.1.4.0', '/u01/app/oracle/middleware')
) AS v(name, ver, home);


-- gbx-wls-dr-01: IAM DR node
WITH ins AS (
  INSERT INTO client_globex.wls_domains
    (server_id, domain_name, domain_home, wls_version, wls_edition,
     admin_server_host, admin_server_port, is_active, last_seen, discovery_run_id)
  SELECT s.server_id,
    'globex_iam_domain',
    '/u01/app/oracle/middleware/user_projects/domains/globex_iam_domain',
    '12.2.1.4.0', 'WebLogic Suite',
    'gbx-wls-dr-01.globex.internal', 7001, TRUE, NOW(), 'sample-run-001'
  FROM client_globex.oracle_servers s WHERE s.hostname = 'gbx-wls-dr-01'
  ON CONFLICT (server_id, domain_name) DO UPDATE SET
    wls_version = EXCLUDED.wls_version, wls_edition = EXCLUDED.wls_edition,
    last_seen = NOW()
  RETURNING domain_id
),
ms AS (
  INSERT INTO client_globex.wls_managed_servers
    (domain_id, server_id, managed_server_name, listen_port, ssl_port,
     cluster_name, machine_name, state, last_seen, discovery_run_id)
  SELECT i.domain_id, s.server_id, v.ms_name, v.port, v.ssl, v.cluster, v.machine, 'SHUTDOWN', NOW(), 'sample-run-001'
  FROM ins i, client_globex.oracle_servers s,
  (VALUES
    ('oam_server_dr', 14100, 14101, 'oam_cluster', 'machine-gbx-wls-dr-01'),
    ('oig_server_dr', 14000, 14001, 'oig_cluster', 'machine-gbx-wls-dr-01')
  ) AS v(ms_name, port, ssl, cluster, machine)
  WHERE s.hostname = 'gbx-wls-dr-01'
)
INSERT INTO client_globex.wls_installed_products
  (domain_id, product_name, product_version, home_path, discovery_run_id)
SELECT i.domain_id, v.name, v.ver, v.home, 'sample-run-001'
FROM ins i,
(VALUES
  ('Oracle Access Manager',      '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle Identity Governance', '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle Coherence',           '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle WebLogic Server',     '12.2.1.4.0', '/u01/app/oracle/middleware'),
  ('Oracle JRF',                 '12.2.1.4.0', '/u01/app/oracle/middleware')
) AS v(name, ver, home);


-- gbx-wls-uat-01: UAT domain (WLS EE, no middleware products)
WITH ins AS (
  INSERT INTO client_globex.wls_domains
    (server_id, domain_name, domain_home, wls_version, wls_edition,
     admin_server_host, admin_server_port, is_active, last_seen, discovery_run_id)
  SELECT s.server_id,
    'globex_uat_domain',
    '/u01/app/oracle/middleware/user_projects/domains/globex_uat_domain',
    '12.2.1.4.0', 'WebLogic Server Enterprise Edition',
    'gbx-wls-uat-01.globex.internal', 7001, TRUE, NOW(), 'sample-run-001'
  FROM client_globex.oracle_servers s WHERE s.hostname = 'gbx-wls-uat-01'
  ON CONFLICT (server_id, domain_name) DO UPDATE SET
    wls_version = EXCLUDED.wls_version, wls_edition = EXCLUDED.wls_edition,
    last_seen = NOW()
  RETURNING domain_id
)
INSERT INTO client_globex.wls_installed_products
  (domain_id, product_name, product_version, home_path, discovery_run_id)
SELECT i.domain_id, v.name, v.ver, v.home, 'sample-run-001'
FROM ins i,
(VALUES
  ('Oracle WebLogic Server', '12.2.1.4.0', '/u01/app/oracle/middleware')
) AS v(name, ver, home);


-- ===========================================================================
-- CSI CONTRACTS — mixed DB + WebLogic, client-locked and shareable
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- CSI F: Acme Corp — Mixed DB + WLS contract (client-locked to acme)
-- Covers the production ERP DB servers AND the WLS SOA cluster
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_csi INTEGER;
BEGIN
  IF EXISTS (SELECT 1 FROM shared.csi_contracts WHERE vendor_reference = 'ORD-2024-ACM-WLS-01') THEN
    RAISE NOTICE 'Contract ORD-2024-ACM-WLS-01 already exists — skipping.'; RETURN;
  END IF;
  v_csi := shared.add_csi(
    p_contract_name  => 'Acme ERP Platform — DB & Middleware 2024',
    p_csi_number     => '11112222',
    p_vendor_ref     => 'ORD-2024-ACM-WLS-01',
    p_purchase_date  => '2024-02-01',
    p_support_start  => '2024-02-01',
    p_support_expiry => '2027-02-01',
    p_currency       => 'USD',
    p_locked_to      => 'acme',
    p_notes          => 'Covers ERP DB tier and SOA/OSB middleware cluster'
  );

  -- DB lines
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Enterprise Edition',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 128,
    p_unit_price     => 47500.00,
    p_annual_support => 1334400.00,
    p_notes          => 'Covers db-prod-01, db-prod-02 and DR mirrors'
  );
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Diagnostics Pack',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 128,
    p_unit_price     => 7500.00,
    p_annual_support => 211200.00
  );
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Tuning Pack',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 64,
    p_unit_price     => 5000.00,
    p_annual_support => 70400.00,
    p_notes          => 'Prod servers only'
  );

  -- WLS lines
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle WebLogic Server Enterprise Edition',
    p_product_family => 'oracle_weblogic',
    p_metric         => 'processor',
    p_quantity       => 64,
    p_unit_price     => 25000.00,
    p_annual_support => 352000.00,
    p_notes          => 'SOA cluster: wls-prod-01, wls-prod-02, wls-dr-01'
  );
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle SOA Suite',
    p_product_family => 'oracle_weblogic',
    p_metric         => 'processor',
    p_quantity       => 32,
    p_unit_price     => 23000.00,
    p_annual_support => 161920.00,
    p_notes          => 'Prod SOA cluster nodes only (wls-prod-01, wls-prod-02)'
  );
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Service Bus',
    p_product_family => 'oracle_weblogic',
    p_metric         => 'processor',
    p_quantity       => 48,
    p_unit_price     => 9800.00,
    p_annual_support => 103488.00,
    p_notes          => 'SOA cluster + gateway node'
  );
END $$;


-- ---------------------------------------------------------------------------
-- CSI G: Globex Corp — WLS Suite for IAM platform (client-locked to globex)
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_csi INTEGER;
BEGIN
  IF EXISTS (SELECT 1 FROM shared.csi_contracts WHERE vendor_reference = 'ORD-2024-GBX-WLS-01') THEN
    RAISE NOTICE 'Contract ORD-2024-GBX-WLS-01 already exists — skipping.'; RETURN;
  END IF;
  v_csi := shared.add_csi(
    p_contract_name  => 'Globex Identity & Access Management Platform 2024',
    p_csi_number     => '33334444',
    p_vendor_ref     => 'ORD-2024-GBX-WLS-01',
    p_purchase_date  => '2024-04-01',
    p_support_start  => '2024-04-01',
    p_support_expiry => '2027-04-01',
    p_currency       => 'USD',
    p_locked_to      => 'globex',
    p_notes          => 'WebLogic Suite for OAM / OIG / OUD — 3 physical nodes'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle WebLogic Suite',
    p_product_family => 'oracle_weblogic',
    p_metric         => 'processor',
    p_quantity       => 192,
    p_unit_price     => 45000.00,
    p_annual_support => 1900800.00,
    p_notes          => 'gbx-wls-prod-01, gbx-wls-prod-02, gbx-wls-dr-01 (2×32 phys cores each)'
  );
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Coherence',
    p_product_family => 'oracle_coherence',
    p_metric         => 'processor',
    p_quantity       => 128,
    p_unit_price     => 23000.00,
    p_annual_support => 648960.00,
    p_notes          => 'Prod nodes only'
  );
END $$;


-- ---------------------------------------------------------------------------
-- CSI H: Shareable — Pooled WLS EE + DB SE2 (available to any client)
-- Intended for UAT / dev / smaller workloads
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_csi INTEGER;
BEGIN
  IF EXISTS (SELECT 1 FROM shared.csi_contracts WHERE vendor_reference = 'ORD-2023-SHARED-WLS-01') THEN
    RAISE NOTICE 'Contract ORD-2023-SHARED-WLS-01 already exists — skipping.'; RETURN;
  END IF;
  v_csi := shared.add_csi(
    p_contract_name  => 'Shared Middleware & DB Pool — Non-Production 2023',
    p_csi_number     => '55556666',
    p_vendor_ref     => 'ORD-2023-SHARED-WLS-01',
    p_purchase_date  => '2023-07-01',
    p_support_start  => '2023-07-01',
    p_support_expiry => '2026-07-01',
    p_currency       => 'USD',
    p_locked_to      => NULL,
    p_notes          => 'Pooled non-prod WLS EE and DB SE2 — allocatable to acme or globex UAT/dev'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle WebLogic Server Enterprise Edition',
    p_product_family => 'oracle_weblogic',
    p_metric         => 'processor',
    p_quantity       => 32,
    p_unit_price     => 25000.00,
    p_annual_support => 176000.00,
    p_notes          => 'Shared UAT pool — allocate to wls-uat-01 or gbx-wls-uat-01'
  );
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Standard Edition 2',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 8,
    p_unit_price     => 17500.00,
    p_annual_support => 30800.00,
    p_notes          => 'Shared SE2 pool for dev/test DB servers'
  );
END $$;


-- ---------------------------------------------------------------------------
-- CSI I: Shareable — WLS EE + DB EE options bundle (cross-client prod pool)
-- Covers additional WLS EE capacity and associated DB Diagnostics/Tuning
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_csi INTEGER;
BEGIN
  IF EXISTS (SELECT 1 FROM shared.csi_contracts WHERE vendor_reference = 'ORD-2024-SHARED-WLS-02') THEN
    RAISE NOTICE 'Contract ORD-2024-SHARED-WLS-02 already exists — skipping.'; RETURN;
  END IF;
  v_csi := shared.add_csi(
    p_contract_name  => 'Shared Production Middleware & DB Options Pool 2024',
    p_csi_number     => '77778888',
    p_vendor_ref     => 'ORD-2024-SHARED-WLS-02',
    p_purchase_date  => '2024-06-01',
    p_support_start  => '2024-06-01',
    p_support_expiry => '2027-06-01',
    p_currency       => 'USD',
    p_locked_to      => NULL,
    p_notes          => 'Production overflow pool — WLS EE capacity + DB options for overflow allocations'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle WebLogic Server Enterprise Edition',
    p_product_family => 'oracle_weblogic',
    p_metric         => 'processor',
    p_quantity       => 64,
    p_unit_price     => 25000.00,
    p_annual_support => 352000.00,
    p_notes          => 'Shared prod overflow — allocatable to any client'
  );
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Enterprise Edition',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 32,
    p_unit_price     => 47500.00,
    p_annual_support => 333200.00,
    p_notes          => 'Overflow DB EE licences'
  );
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Diagnostics Pack',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 32,
    p_unit_price     => 7500.00,
    p_annual_support => 52800.00
  );
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Advanced Compression',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 16,
    p_unit_price     => 11500.00,
    p_annual_support => 40480.00
  );
END $$;


-- ===========================================================================
-- SERVER → CSI MAPPINGS
-- Map the WLS servers to the contracts above.
-- Each block is idempotent via ON CONFLICT DO NOTHING.
-- ===========================================================================

-- CSI F (ORD-2024-ACM-WLS-01): Acme prod WLS cluster + OSB gateway
INSERT INTO client_acme.server_csi_map (server_id, csi_id, product_family)
SELECT s.server_id, c.csi_id, 'oracle_weblogic'
FROM client_acme.oracle_servers s
CROSS JOIN shared.csi_contracts c
WHERE s.hostname IN ('wls-prod-01', 'wls-prod-02', 'wls-prod-03', 'wls-dr-01')
  AND c.vendor_reference = 'ORD-2024-ACM-WLS-01'
  AND NOT EXISTS (
    SELECT 1 FROM client_acme.server_csi_map m
    WHERE m.server_id = s.server_id AND m.csi_id = c.csi_id AND m.product_family = 'oracle_weblogic'
  );

-- CSI G (ORD-2024-GBX-WLS-01): Globex prod WLS servers
INSERT INTO client_globex.server_csi_map (server_id, csi_id, product_family)
SELECT s.server_id, c.csi_id, 'oracle_weblogic'
FROM client_globex.oracle_servers s
CROSS JOIN shared.csi_contracts c
WHERE s.hostname IN ('gbx-wls-prod-01', 'gbx-wls-prod-02', 'gbx-wls-dr-01')
  AND c.vendor_reference = 'ORD-2024-GBX-WLS-01'
  AND NOT EXISTS (
    SELECT 1 FROM client_globex.server_csi_map m
    WHERE m.server_id = s.server_id AND m.csi_id = c.csi_id AND m.product_family = 'oracle_weblogic'
  );

-- CSI H (ORD-2023-SHARED-WLS-01): Shared non-prod pool → acme + globex UAT
INSERT INTO client_acme.server_csi_map (server_id, csi_id, product_family)
SELECT s.server_id, c.csi_id, 'oracle_weblogic'
FROM client_acme.oracle_servers s
CROSS JOIN shared.csi_contracts c
WHERE s.hostname = 'wls-uat-01'
  AND c.vendor_reference = 'ORD-2023-SHARED-WLS-01'
  AND NOT EXISTS (
    SELECT 1 FROM client_acme.server_csi_map m
    WHERE m.server_id = s.server_id AND m.csi_id = c.csi_id AND m.product_family = 'oracle_weblogic'
  );

INSERT INTO client_globex.server_csi_map (server_id, csi_id, product_family)
SELECT s.server_id, c.csi_id, 'oracle_weblogic'
FROM client_globex.oracle_servers s
CROSS JOIN shared.csi_contracts c
WHERE s.hostname = 'gbx-wls-uat-01'
  AND c.vendor_reference = 'ORD-2023-SHARED-WLS-01'
  AND NOT EXISTS (
    SELECT 1 FROM client_globex.server_csi_map m
    WHERE m.server_id = s.server_id AND m.csi_id = c.csi_id AND m.product_family = 'oracle_weblogic'
  );

-- CSI I (ORD-2024-SHARED-WLS-02): Shared prod overflow → acme + globex prod nodes
INSERT INTO client_acme.server_csi_map (server_id, csi_id, product_family)
SELECT s.server_id, c.csi_id, 'oracle_weblogic'
FROM client_acme.oracle_servers s
CROSS JOIN shared.csi_contracts c
WHERE s.hostname IN ('wls-prod-01', 'wls-prod-02')
  AND c.vendor_reference = 'ORD-2024-SHARED-WLS-02'
  AND NOT EXISTS (
    SELECT 1 FROM client_acme.server_csi_map m
    WHERE m.server_id = s.server_id AND m.csi_id = c.csi_id AND m.product_family = 'oracle_weblogic'
  );

INSERT INTO client_globex.server_csi_map (server_id, csi_id, product_family)
SELECT s.server_id, c.csi_id, 'oracle_weblogic'
FROM client_globex.oracle_servers s
CROSS JOIN shared.csi_contracts c
WHERE s.hostname IN ('gbx-wls-prod-01', 'gbx-wls-prod-02')
  AND c.vendor_reference = 'ORD-2024-SHARED-WLS-02'
  AND NOT EXISTS (
    SELECT 1 FROM client_globex.server_csi_map m
    WHERE m.server_id = s.server_id AND m.csi_id = c.csi_id AND m.product_family = 'oracle_weblogic'
  );

-- =============================================================================
-- Oracle SAM v2 — Database Initialization Script
-- Run this after schema files to create roles, clients, and seed data.
--
-- Execute in order:
--   psql oracle_sam -f database/admin/01_admin_schema.sql
--   psql oracle_sam -f database/shared/02_shared_schema.sql
--   psql oracle_sam -f database/client_template/03_client_template_functions.sql
--   psql oracle_sam -f database/migrations/00_init.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. DATABASE ROLES
-- ---------------------------------------------------------------------------
CREATE ROLE sam_loader     WITH LOGIN PASSWORD 'admin';   -- Ansible writes
CREATE ROLE sam_reader     WITH LOGIN PASSWORD 'admin';   -- Power BI reads
CREATE ROLE sam_admin_role WITH LOGIN PASSWORD 'admin';    -- Full admin

-- Loader: read shared/admin, write to client schemas (granted per schema below)
GRANT USAGE  ON SCHEMA shared, sam_admin TO sam_loader;
GRANT SELECT ON ALL TABLES IN SCHEMA shared    TO sam_loader;
GRANT SELECT ON ALL TABLES IN SCHEMA sam_admin TO sam_loader;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA shared    TO sam_loader;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA sam_admin TO sam_loader;

-- Reader: read-only everywhere (Power BI service account)
GRANT USAGE  ON SCHEMA shared, sam_admin TO sam_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA shared    TO sam_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA sam_admin TO sam_reader;

-- Admin: full access to shared and sam_admin
GRANT ALL ON SCHEMA shared, sam_admin TO sam_admin_role;
GRANT ALL ON ALL TABLES    IN SCHEMA shared    TO sam_admin_role;
GRANT ALL ON ALL TABLES    IN SCHEMA sam_admin TO sam_admin_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA shared    TO sam_admin_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA sam_admin TO sam_admin_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA shared    TO sam_admin_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA sam_admin TO sam_admin_role;

-- ---------------------------------------------------------------------------
-- 2. PROVISION CLIENTS
-- ---------------------------------------------------------------------------
SELECT sam_admin.provision_client('acme',   'Acme Corp',   'admin@acme.example.com');
SELECT sam_admin.provision_client('globex', 'Globex Corp', 'admin@globex.example.com');

-- Add more clients:
-- SELECT sam_admin.provision_client('contoso', 'Contoso Ltd', 'sam@contoso.example.com');

-- ---------------------------------------------------------------------------
-- 3. GRANT ROLES ON EACH CLIENT SCHEMA
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_schema TEXT;
BEGIN
  FOR v_schema IN SELECT schema_name FROM sam_admin.clients WHERE is_active = TRUE
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO sam_loader, sam_reader, sam_admin_role', v_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA %I TO sam_loader', v_schema);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO sam_reader', v_schema);
    EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO sam_admin_role', v_schema);
    EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO sam_loader', v_schema);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO sam_reader', v_schema);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 4. BUILD CROSS-CLIENT SUMMARY VIEW
-- ---------------------------------------------------------------------------
SELECT shared.refresh_cross_client_summary();

-- ---------------------------------------------------------------------------
-- 5. SEED CSI CONTRACTS AND LINE ITEMS
--
-- Pattern: add_csi() creates the contract header, add_csi_line() adds each
-- product within that contract. One CSI can contain many product lines.
-- All functions use client_code strings — no integer IDs needed.
-- ---------------------------------------------------------------------------

-- ---- CSI A: Shared Oracle Database EE pool --------------------------------
-- Shareable across clients. Acme gets 60 licences, Globex gets 40.
-- Contains EE base licence plus three paid options.
DO $$
DECLARE v_csi INTEGER;
BEGIN
  v_csi := shared.add_csi(
    p_contract_name  => 'Group Oracle DB EE Pool 2023',
    p_csi_number     => '11111111',
    p_vendor_ref     => 'ORD-2023-0001',
    p_purchase_date  => '2023-01-01',
    p_support_start  => '2023-01-01',
    p_support_expiry => '2026-01-01',
    p_currency       => 'USD',
    p_policy         => 'shareable',
    p_notes          => 'Group EE pool shared across Acme (60) and Globex (40)'
  );

  -- Line 1: Base database licence
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Enterprise Edition',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 100,
    p_unit_price     => 47500.00,
    p_annual_support => 1045000.00,
    p_notes          => 'Base EE licence'
  );

  -- Line 2: Diagnostic Pack (required for AWR, ADDM, ASH)
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Diagnostic Pack',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 100,
    p_unit_price     => 7500.00,
    p_annual_support => 165000.00,
    p_notes          => 'Required for AWR / ADDM / ASH'
  );

  -- Line 3: Tuning Pack (requires Diagnostic Pack)
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Tuning Pack',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 100,
    p_unit_price     => 5000.00,
    p_annual_support => 110000.00
  );

  -- Line 4: Partitioning
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Partitioning',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 100,
    p_unit_price     => 11500.00,
    p_annual_support => 253000.00
  );

  -- Assign: Acme gets 60 licences, Globex gets 40
  PERFORM shared.assign_csi_to_client(v_csi, 'acme',   'shareable', 60, 'Acme 60-licence share');
  PERFORM shared.assign_csi_to_client(v_csi, 'globex', 'shareable', 40, 'Globex 40-licence share');
END $$;


-- ---- CSI B: Shared WebLogic Server pool -----------------------------------
-- Full pool currently allocated to Acme only.
DO $$
DECLARE v_csi INTEGER;
BEGIN
  v_csi := shared.add_csi(
    p_contract_name  => 'Group WebLogic Server EE Pool 2023',
    p_csi_number     => '22222222',
    p_vendor_ref     => 'ORD-2023-0002',
    p_purchase_date  => '2023-06-01',
    p_support_start  => '2023-06-01',
    p_support_expiry => '2026-06-01',
    p_currency       => 'USD',
    p_policy         => 'shareable',
    p_notes          => 'WLS pool — Acme currently using full allocation'
  );

  -- Line 1: WebLogic Server EE
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle WebLogic Server Enterprise Edition',
    p_product_family => 'oracle_weblogic',
    p_metric         => 'processor',
    p_quantity       => 50,
    p_unit_price     => 45000.00,
    p_annual_support => 495000.00
  );

  -- Line 2: Oracle Coherence (often bundled in WLS Suite)
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Coherence',
    p_product_family => 'oracle_coherence',
    p_metric         => 'processor',
    p_quantity       => 50,
    p_unit_price     => 23000.00,
    p_annual_support => 253000.00
  );

  -- Assign full pool to Acme (NULL = full contract available)
  PERFORM shared.assign_csi_to_client(v_csi, 'acme', 'shareable', NULL, 'Acme — full WLS pool');
END $$;


-- ---- CSI C: Client-locked SE2 for Globex ----------------------------------
-- Purchased under Globex's legal entity — cannot be shared.
-- p_locked_to automatically sets policy = client_locked and assigns to globex.
DO $$
DECLARE v_csi INTEGER;
BEGIN
  v_csi := shared.add_csi(
    p_contract_name  => 'Globex SE2 Contract 2022',
    p_csi_number     => '33333333',
    p_vendor_ref     => 'ORD-2022-0099',
    p_purchase_date  => '2022-01-01',
    p_support_start  => '2022-01-01',
    p_support_expiry => '2025-01-01',
    p_currency       => 'USD',
    p_locked_to      => 'globex',       -- client_locked, auto-assigns to globex
    p_notes          => 'Purchased under Globex legal entity — cannot be shared'
  );

  -- Line 1: SE2 base licence
  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Standard Edition 2',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 20,
    p_unit_price     => 17500.00,
    p_annual_support => 77000.00,
    p_notes          => 'SE2 — max 2 processor licences per server'
  );
END $$;


-- ---- CSI D: Acme-locked Advanced Security option --------------------------
-- Purchased under Acme's entity for their compliance requirements.
DO $$
DECLARE v_csi INTEGER;
BEGIN
  v_csi := shared.add_csi(
    p_contract_name  => 'Acme Advanced Security 2024',
    p_csi_number     => '55555555',
    p_vendor_ref     => 'ORD-2024-0010',
    p_purchase_date  => '2024-01-15',
    p_support_start  => '2024-01-15',
    p_support_expiry => '2027-01-15',
    p_currency       => 'USD',
    p_locked_to      => 'acme',
    p_notes          => 'Acme compliance requirement — TDE and network encryption'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Advanced Security',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 60,
    p_unit_price     => 15000.00,
    p_annual_support => 198000.00,
    p_notes          => 'Covers TDE, network encryption, data redaction'
  );
END $$;


-- ---- CSI E: Unassigned — recently purchased, policy not yet set -----------
-- Appears in shared.unassigned_licences with allocation_status = 'NEEDS POLICY'.
DO $$
DECLARE v_csi INTEGER;
BEGIN
  v_csi := shared.add_csi(
    p_contract_name  => 'New EE Purchase Q1 2024',
    p_csi_number     => '44444444',
    p_vendor_ref     => 'ORD-2024-0022',
    p_purchase_date  => '2024-03-01',
    p_support_start  => '2024-03-01',
    p_support_expiry => '2027-03-01',
    p_currency       => 'USD'
    -- p_policy omitted — defaults to 'unassigned'
  );

  PERFORM shared.add_csi_line(
    p_csi_id         => v_csi,
    p_product_name   => 'Oracle Database Enterprise Edition',
    p_product_family => 'oracle_database',
    p_metric         => 'processor',
    p_quantity       => 25,
    p_unit_price     => 47500.00,
    p_annual_support => 261250.00,
    p_notes          => 'Awaiting decision on which client to assign to'
  );
END $$;


-- ---------------------------------------------------------------------------
-- 6. VERIFY SETUP
-- ---------------------------------------------------------------------------
SELECT '=== Clients ===' AS section;
SELECT client_code, schema_name, is_active,
  (SELECT COUNT(*) FROM pg_tables WHERE schemaname = c.schema_name) AS tables_created
FROM sam_admin.clients c;

SELECT '=== CSI Contracts ===' AS section;
SELECT csi_number, contract_name, sharing_policy, owning_client,
       assigned_clients, line_count, total_licences,
       total_licence_cost, total_annual_support, total_contract_value,
       allocation_status
FROM shared.csi_contract_summary
ORDER BY csi_number;

SELECT '=== Line Items ===' AS section;
SELECT csi_number, line_number, product_name, product_family,
       license_metric, quantity, unit_price, total_price,
       annual_support_cost, total_line_cost
FROM shared.entitlement_line_detail
ORDER BY csi_number, line_number;

SELECT '=== Unassigned / Action Required ===' AS section;
SELECT csi_number, contract_name, sharing_policy,
       allocation_status, total_licences, total_contract_value
FROM shared.unassigned_licences;

-- ---------------------------------------------------------------------------
-- 7. EXAMPLE: ASSIGN CSIs TO SPECIFIC SERVERS
-- Run after Ansible discovery has populated oracle_servers.
-- Replace hostnames with real values from your environment.
-- ---------------------------------------------------------------------------

-- Pattern: one server covered by a single CSI for DB
-- INSERT INTO client_acme.server_csi_map
--   (server_id, csi_id, product_family, notes, assigned_by)
-- SELECT s.server_id, 1, 'oracle_database',
--        'EE base covered by group pool CSI 11111111', 'sam_admin'
-- FROM   client_acme.oracle_servers s
-- WHERE  s.hostname = 'acme-db-prod-01.acme.example.com';

-- Pattern: same server, second CSI for a separate options contract
-- INSERT INTO client_acme.server_csi_map
--   (server_id, csi_id, line_id, product_family, notes, assigned_by)
-- SELECT s.server_id, 4, 1, 'oracle_database',
--        'Advanced Security option from CSI 55555555 line 1', 'sam_admin'
-- FROM   client_acme.oracle_servers s
-- WHERE  s.hostname = 'acme-db-prod-01.acme.example.com';

-- Pattern: server covered by a CSI for WLS
-- INSERT INTO client_acme.server_csi_map
--   (server_id, csi_id, product_family, notes, assigned_by)
-- SELECT s.server_id, 2, 'oracle_weblogic',
--        'WLS EE covered by group pool CSI 22222222', 'sam_admin'
-- FROM   client_acme.oracle_servers s
-- WHERE  s.hostname = 'acme-wls-prod-01.acme.example.com';

-- Check coverage status after assigning:
-- SELECT hostname, product_family, product_detail, licences_required,
--        assigned_csi_count, assigned_csis, coverage_status, coverage_gap
-- FROM   client_acme.server_csi_coverage
-- ORDER  BY coverage_status, hostname;

-- Find all servers with no CSI assigned (audit gap report):
-- SELECT hostname, product_family, product_detail, licences_required, coverage_gap
-- FROM   client_acme.server_csi_coverage
-- WHERE  coverage_status = 'NO CSI ASSIGNED'
-- ORDER  BY hostname;

-- Trying to assign a client_locked CSI to the wrong client:
--   SELECT shared.assign_csi_to_client(3, 'acme', 'client_locked');
--   ERROR: CSI contract 3 is client_locked to client_id N.
--          It cannot be assigned to client_id M.

-- Trying to assign an unassigned-policy CSI directly:
--   INSERT INTO shared.csi_client_map (csi_id, client_id) VALUES (5, 1);
--   ERROR: CSI contract 5 has sharing_policy = unassigned.
--          Set policy to client_locked or shareable before assigning.

-- Changing owner of a CSI and locking it in one call:
--   SELECT shared.set_csi_owner(5, 'acme', p_lock => TRUE);

-- Adding a new client mid-operation:
--   SELECT sam_admin.provision_client('contoso', 'Contoso Ltd', 'sam@contoso.com');
--   SELECT shared.assign_csi_to_client(1, 'contoso', 'shareable', 20, 'Contoso share');
--   SELECT shared.refresh_cross_client_summary();

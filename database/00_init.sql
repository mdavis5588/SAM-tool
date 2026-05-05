-- =============================================================================
-- Oracle SAM v2 - Database Initialization Script
-- Run this to set up a brand new instance, or use the migration guide
-- in docs/MIGRATIONS.md to upgrade from v1.
-- =============================================================================

-- 1. Create the database (run as superuser outside the DB)
--    createdb oracle_sam

-- 2. Run schema files IN ORDER
\i database/admin/01_admin_schema.sql
\i database/shared/02_shared_schema.sql
\i database/client_template/03_client_template_functions.sql

-- 3. Create database roles
CREATE ROLE sam_loader WITH LOGIN PASSWORD 'changeme_loader';
CREATE ROLE sam_reader WITH LOGIN PASSWORD 'changeme_reader';
CREATE ROLE sam_admin_role WITH LOGIN PASSWORD 'changeme_admin';

-- Grant loader: can write to any client schema and read shared
GRANT USAGE ON SCHEMA shared, sam_admin TO sam_loader;
GRANT SELECT ON ALL TABLES IN SCHEMA shared TO sam_loader;
GRANT SELECT ON ALL TABLES IN SCHEMA sam_admin TO sam_loader;
-- Client schemas are granted individually when provisioned (see below)

-- Grant reader: read-only across everything (Power BI service account)
GRANT USAGE ON SCHEMA shared, sam_admin TO sam_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA shared TO sam_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA sam_admin TO sam_reader;

-- Grant admin: full access
GRANT ALL ON SCHEMA shared, sam_admin TO sam_admin_role;
GRANT ALL ON ALL TABLES IN SCHEMA shared TO sam_admin_role;
GRANT ALL ON ALL TABLES IN SCHEMA sam_admin TO sam_admin_role;

-- 4. Provision your first clients
SELECT sam_admin.provision_client('acme',   'Acme Corp',   'admin@acme.example.com');
SELECT sam_admin.provision_client('globex', 'Globex Corp', 'admin@globex.example.com');
-- Add more clients as needed:
-- SELECT sam_admin.provision_client('contoso', 'Contoso Ltd', 'sam@contoso.example.com');

-- 5. Grant loader and reader to each client schema (run after provisioning each client)
DO $$
DECLARE
  v_schema TEXT;
BEGIN
  FOR v_schema IN SELECT schema_name FROM sam_admin.clients WHERE is_active = TRUE
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO sam_loader, sam_reader', v_schema);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA %I TO sam_loader', v_schema);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO sam_reader', v_schema);
    EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO sam_loader', v_schema);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO sam_reader', v_schema);
  END LOOP;
END $$;

-- 6. Build the cross-client summary view
SELECT shared.refresh_cross_client_summary();

-- 7. Seed entitlements using add_entitlement() — client codes only, no integer IDs.

-- Shareable group EE pool — can be split across clients, no single owner
SELECT shared.add_entitlement(
  p_csi            => '11111111',
  p_product_name   => 'Oracle Database Enterprise Edition',
  p_product_family => 'oracle_database',
  p_metric         => 'processor',
  p_quantity       => 100,
  p_purchase_date  => '2023-01-01',
  p_support_expiry => '2026-01-01',
  p_policy         => 'shareable',
  p_notes          => 'Group EE pool — split across clients as needed'
);

-- Shareable WLS pool
SELECT shared.add_entitlement(
  p_csi            => '22222222',
  p_product_name   => 'Oracle WebLogic Server Enterprise Edition',
  p_product_family => 'oracle_weblogic',
  p_metric         => 'processor',
  p_quantity       => 50,
  p_purchase_date  => '2023-06-01',
  p_support_expiry => '2026-06-01',
  p_policy         => 'shareable'
);

-- Client-locked SE2 — purchased under Globex's entity, locked to them.
-- p_locked_to sets sharing_policy = 'client_locked' and auto-assigns to globex.
SELECT shared.add_entitlement(
  p_csi            => '33333333',
  p_product_name   => 'Oracle Database Standard Edition 2',
  p_product_family => 'oracle_database',
  p_metric         => 'processor',
  p_quantity       => 20,
  p_purchase_date  => '2022-01-01',
  p_support_expiry => '2025-01-01',
  p_locked_to      => 'globex',
  p_notes          => 'Purchased under Globex legal entity — cannot be shared'
);

-- Unassigned — recently purchased, policy not yet decided.
-- Omit p_locked_to and p_policy to leave as 'unassigned' (default).
SELECT shared.add_entitlement(
  p_csi            => '44444444',
  p_product_name   => 'Oracle Database Enterprise Edition',
  p_product_family => 'oracle_database',
  p_metric         => 'processor',
  p_quantity       => 25,
  p_purchase_date  => '2024-03-01',
  p_support_expiry => '2027-03-01',
  p_notes          => 'Recently purchased — awaiting policy decision'
);

-- 8. Assign the shareable entitlements to clients.
--    CSI 11111111 (EE pool) — split 60 for Acme, 40 for Globex
SELECT shared.assign_entitlement_to_client(1, 'acme',   'shareable', 60, 'Acme EE allocation');
SELECT shared.assign_entitlement_to_client(1, 'globex', 'shareable', 40, 'Globex EE allocation');

--    CSI 22222222 (WLS pool) — full pool to Acme for now
SELECT shared.assign_entitlement_to_client(2, 'acme', 'shareable', NULL, 'Acme WLS — full pool');

--    CSI 33333333 was already auto-assigned to globex by add_entitlement().

--    CSI 44444444 is intentionally left unassigned — it will appear in
--    shared.unassigned_licences with allocation_status = 'NEEDS POLICY'.

-- ---- Examples showing the guard rails ----
-- These are commented out. Uncomment to test the error messages.

-- Trying to lock a CSI to the wrong client (33333333 is locked to globex):
--   SELECT shared.assign_entitlement_to_client(3, 'acme', 'client_locked');
--   ERROR: Entitlement 3 is client_locked to client_id N. It cannot be assigned to client_id M.

-- Trying to assign an unassigned-policy CSI directly:
--   INSERT INTO shared.entitlement_client_map (entitlement_id, client_id) VALUES (4, 1);
--   ERROR: Entitlement 4 has sharing_policy = unassigned. Set policy before assigning.

-- Using set_entitlement_owner to declare ownership without assigning:
--   SELECT shared.set_entitlement_owner(4, 'acme');            -- sets owner, keeps policy
--   SELECT shared.set_entitlement_owner(4, 'acme', lock => TRUE); -- sets owner AND locks it

-- Verify setup
SELECT
  c.client_code,
  c.schema_name,
  c.is_active,
  (SELECT COUNT(*) FROM pg_tables WHERE schemaname = c.schema_name) AS tables_created
FROM sam_admin.clients c;

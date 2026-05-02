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

-- 7. Seed entitlements (examples — replace with real CSI data)
INSERT INTO shared.license_entitlements
  (csi_number, product_name, product_family, license_metric, quantity, purchase_date, support_expiry)
VALUES
  ('11111111', 'Oracle Database Enterprise Edition', 'oracle_database', 'processor', 100, '2023-01-01', '2026-01-01'),
  ('22222222', 'Oracle WebLogic Server Enterprise Edition', 'oracle_weblogic', 'processor', 50, '2023-06-01', '2026-06-01'),
  ('33333333', 'Oracle Database Standard Edition 2', 'oracle_database', 'processor', 20, '2022-01-01', '2025-01-01');

-- 8. Assign entitlements to clients
-- CSI 11111111 (ODB EE) — split: 60 for Acme, 40 for Globex
INSERT INTO shared.entitlement_client_map (entitlement_id, client_id, allocated_quantity, allocation_notes)
SELECT 1, c.client_id, 60, 'Acme allocation of shared EE licence pool'
FROM   sam_admin.clients c WHERE c.client_code = 'acme';

INSERT INTO shared.entitlement_client_map (entitlement_id, client_id, allocated_quantity, allocation_notes)
SELECT 1, c.client_id, 40, 'Globex allocation of shared EE licence pool'
FROM   sam_admin.clients c WHERE c.client_code = 'globex';

-- CSI 22222222 (WLS) — Acme only (full entitlement)
INSERT INTO shared.entitlement_client_map (entitlement_id, client_id)
SELECT 2, c.client_id FROM sam_admin.clients c WHERE c.client_code = 'acme';

-- CSI 33333333 (SE2) — Globex only (full entitlement)
INSERT INTO shared.entitlement_client_map (entitlement_id, client_id)
SELECT 3, c.client_id FROM sam_admin.clients c WHERE c.client_code = 'globex';

-- Verify setup
SELECT
  c.client_code,
  c.schema_name,
  c.is_active,
  (SELECT COUNT(*) FROM pg_tables WHERE schemaname = c.schema_name) AS tables_created
FROM sam_admin.clients c;

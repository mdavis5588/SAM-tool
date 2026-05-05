-- =============================================================================
-- Shared Schema
-- Holds data that belongs to no single client:
--   - License entitlements (CSIs / ULAs)
--   - Entitlement-to-client mapping (many-to-many)
--   - Oracle Core Factor Table
--   - Cross-client admin roll-up views
-- Run AFTER 01_admin_schema.sql.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS shared;
SET search_path = shared, sam_admin, public;

-- ---------------------------------------------------------------------------
-- ENUM TYPES
-- ---------------------------------------------------------------------------
CREATE TYPE shared.license_metric AS ENUM
  ('named_user_plus', 'processor', 'ula', 'cloud_license', 'full_use');

CREATE TYPE shared.license_status AS ENUM
  ('active', 'expired', 'pending', 'terminated');

CREATE TYPE shared.product_family AS ENUM
  ('oracle_database', 'oracle_weblogic', 'oracle_middleware',
   'oracle_java', 'oracle_coherence', 'other');

-- ---------------------------------------------------------------------------
-- LICENSE ENTITLEMENTS
-- What you (or your clients) actually own from Oracle.
-- One CSI can be assigned to multiple clients via entitlement_client_map.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.license_entitlements (
  entitlement_id    SERIAL PRIMARY KEY,
  csi_number        TEXT,                  -- Oracle Customer Support Identifier
  product_name      TEXT NOT NULL,         -- Exact Oracle product name
  product_family    shared.product_family NOT NULL DEFAULT 'oracle_database',
  license_metric    shared.license_metric NOT NULL DEFAULT 'processor',
  quantity          NUMERIC(10,2) NOT NULL,
  purchase_date     DATE,
  support_start     DATE,
  support_expiry    DATE,
  ula_expiry        DATE,                  -- Unlimited Licence Agreement end date
  vendor_reference  TEXT,                  -- Oracle order number / LMS ref
  is_ula            BOOLEAN NOT NULL DEFAULT FALSE,
  notes             TEXT,
  status            shared.license_status NOT NULL DEFAULT 'active',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_quantity  CHECK (quantity >= 0),
  CONSTRAINT chk_csi_fmt   CHECK (csi_number IS NULL OR csi_number ~ '^\d+$')
);

CREATE INDEX idx_ent_csi     ON shared.license_entitlements (csi_number);
CREATE INDEX idx_ent_product ON shared.license_entitlements (product_name);
CREATE INDEX idx_ent_family  ON shared.license_entitlements (product_family);
CREATE INDEX idx_ent_status  ON shared.license_entitlements (status);

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION shared.touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

CREATE TRIGGER trg_ent_updated
  BEFORE UPDATE ON shared.license_entitlements
  FOR EACH ROW EXECUTE FUNCTION shared.touch_updated_at();

-- ---------------------------------------------------------------------------
-- ENTITLEMENT → CLIENT MAP
-- Many-to-many: one CSI can cover multiple clients (e.g. group ULA),
-- and a client can have multiple entitlements.
-- The allocated_quantity column lets you split a single CSI across clients.
-- Leave it NULL to mean "not split — client uses the full entitlement".
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.entitlement_client_map (
  map_id            SERIAL PRIMARY KEY,
  entitlement_id    INTEGER NOT NULL REFERENCES shared.license_entitlements (entitlement_id) ON DELETE CASCADE,
  client_id         INTEGER NOT NULL REFERENCES sam_admin.clients (client_id) ON DELETE CASCADE,
  allocated_quantity NUMERIC(10,2),        -- NULL = full entitlement available to this client
  allocation_notes  TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (entitlement_id, client_id)
);

CREATE INDEX idx_ecm_entitlement ON shared.entitlement_client_map (entitlement_id);
CREATE INDEX idx_ecm_client      ON shared.entitlement_client_map (client_id);

-- Helper view: entitlements with their client assignments
CREATE OR REPLACE VIEW shared.entitlements_by_client AS
SELECT
  e.entitlement_id,
  e.csi_number,
  e.product_name,
  e.product_family,
  e.license_metric,
  e.quantity                          AS total_quantity,
  COALESCE(m.allocated_quantity, e.quantity) AS client_quantity,
  e.support_expiry,
  e.ula_expiry,
  e.is_ula,
  e.status,
  c.client_id,
  c.client_code,
  c.client_name,
  c.schema_name
FROM   shared.license_entitlements e
JOIN   shared.entitlement_client_map m ON m.entitlement_id = e.entitlement_id
JOIN   sam_admin.clients             c ON c.client_id = m.client_id
WHERE  c.is_active = TRUE;

-- ---------------------------------------------------------------------------
-- ORACLE CORE FACTOR TABLE
-- Source: Oracle Processor Core Factor Table (update from Oracle's website).
-- Shared across all clients — maintained centrally.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.core_factor_table (
  core_factor_id    SERIAL PRIMARY KEY,
  processor_pattern TEXT NOT NULL,       -- ILIKE match pattern
  core_factor       NUMERIC(4,2) NOT NULL,
  notes             TEXT,
  effective_date    DATE NOT NULL DEFAULT CURRENT_DATE,
  is_current        BOOLEAN NOT NULL DEFAULT TRUE,
  source_url        TEXT,
  CONSTRAINT chk_factor CHECK (core_factor > 0 AND core_factor <= 1)
);

-- Seed with Oracle's published values (verify against current Oracle PDF)
INSERT INTO shared.core_factor_table (processor_pattern, core_factor, notes, source_url) VALUES
  ('%Intel%Xeon%',    0.5,  'Intel Xeon multi-core', 'https://www.oracle.com/us/corporate/contracts/processor-core-factor-table-070634.pdf'),
  ('%Intel%Core%',    0.5,  'Intel Core i-series', NULL),
  ('%Intel%Pentium%', 0.5,  'Intel Pentium', NULL),
  ('%Intel%Celeron%', 0.5,  'Intel Celeron', NULL),
  ('%AMD%EPYC%',      0.5,  'AMD EPYC', NULL),
  ('%AMD%Opteron%',   0.5,  'AMD Opteron', NULL),
  ('%AMD%Ryzen%',     0.5,  'AMD Ryzen', NULL),
  ('%ARM%',           0.5,  'ARM-based processors', NULL),
  ('%Apple%M%',       0.5,  'Apple Silicon M-series', NULL),
  ('%IBM%POWER9%',    1.0,  'IBM POWER9', NULL),
  ('%IBM%POWER10%',   1.0,  'IBM POWER10', NULL),
  ('%SPARC%T%',       0.25, 'Oracle SPARC T-series (UltraSPARC T)', NULL),
  ('%SPARC%M%',       0.5,  'Oracle SPARC M-series', NULL),
  ('Unknown',         1.0,  'Default factor for unrecognised processors', NULL);

-- ---------------------------------------------------------------------------
-- WEBLOGIC LICENCE RULES
-- WebLogic licencing is more complex than DB — tracks by edition and
-- whether Coherence/SOA/OAM are also installed (each needs separate licence).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.wls_license_rules (
  rule_id           SERIAL PRIMARY KEY,
  edition_pattern   TEXT NOT NULL,       -- ILIKE match on wls_edition
  metric            shared.license_metric NOT NULL DEFAULT 'processor',
  uses_core_factor  BOOLEAN NOT NULL DEFAULT TRUE,
  notes             TEXT
);

INSERT INTO shared.wls_license_rules (edition_pattern, metric, uses_core_factor, notes) VALUES
  ('%WebLogic Server%',      'processor', TRUE,  'Standard WLS — processor licence with core factor'),
  ('%WebLogic Suite%',       'processor', TRUE,  'WLS Suite — includes Coherence, Tuxedo'),
  ('%Coherence%',            'processor', TRUE,  'Oracle Coherence — separate processor licence'),
  ('%SOA Suite%',            'processor', TRUE,  'Oracle SOA Suite — separate processor licence'),
  ('%Service Bus%',          'processor', TRUE,  'Oracle Service Bus — separate processor licence'),
  ('%Access Manager%',       'processor', TRUE,  'Oracle Access Manager — separate processor licence'),
  ('%Identity Governance%',  'processor', TRUE,  'Oracle Identity Governance — separate processor licence');

-- ---------------------------------------------------------------------------
-- CROSS-CLIENT ADMIN SUMMARY VIEW
-- Only accessible to sam_admin role. Not exposed to client Power BI users.
-- Placeholder created here so the object always exists.
-- Rebuilt by refresh_cross_client_summary() after clients are provisioned.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW shared.cross_client_summary AS
SELECT
  NULL::TEXT     AS client_code,
  NULL::INTEGER  AS client_id,
  NULL::TEXT     AS hostname,
  NULL::TEXT     AS environment,
  NULL::TIMESTAMPTZ AS last_seen,
  NULL::INTEGER  AS cpu_sockets,
  NULL::INTEGER  AS total_physical_cores,
  NULL::TEXT     AS cpu_model,
  NULL::TEXT     AS virt_type,
  NULL::BIGINT   AS oracle_instance_count,
  NULL::BIGINT   AS wls_domain_count
WHERE FALSE;  -- returns no rows until refresh_cross_client_summary() is called

-- Function to rebuild the cross-client summary view dynamically.
-- Call after provisioning a new client or when schemas change.
CREATE OR REPLACE FUNCTION shared.refresh_cross_client_summary()
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_client   RECORD;
  v_parts    TEXT[] := '{}';
  v_sql      TEXT;
  v_fragment TEXT;
BEGIN
  FOR v_client IN
    SELECT client_id, client_code, schema_name
    FROM   sam_admin.clients
    WHERE  is_active = TRUE
  LOOP
    v_fragment := format(
      $u$
        SELECT
          %L::TEXT        AS client_code,
          %s::INTEGER     AS client_id,
          s.hostname,
          s.environment::TEXT,
          s.last_seen,
          p.cpu_sockets,
          p.total_physical_cores,
          p.cpu_model,
          p.virt_type::TEXT,
          COUNT(DISTINCT i.instance_id) AS oracle_instance_count,
          COUNT(DISTINCT d.domain_id)   AS wls_domain_count
        FROM   %I.oracle_servers s
        LEFT   JOIN LATERAL (
          SELECT * FROM %I.oracle_processors op
          WHERE  op.server_id = s.server_id
          ORDER  BY op.recorded_at DESC LIMIT 1
        ) p ON TRUE
        LEFT   JOIN %I.oracle_instances i ON i.server_id = s.server_id AND i.is_active
        LEFT   JOIN %I.wls_domains      d ON d.server_id = s.server_id AND d.is_active
        WHERE  s.is_active
        GROUP  BY s.server_id, s.hostname, s.environment, s.last_seen,
                  p.cpu_sockets, p.total_physical_cores, p.cpu_model, p.virt_type
      $u$,
      v_client.client_code,
      v_client.client_id,
      v_client.schema_name,
      v_client.schema_name,
      v_client.schema_name,
      v_client.schema_name
    );

    v_parts := array_append(v_parts, v_fragment);
  END LOOP;

  IF array_length(v_parts, 1) IS NULL THEN
    -- No clients yet — leave the placeholder view in place
    RETURN;
  END IF;

  -- Join fragments with UNION ALL (no leading UNION ALL problem)
  v_sql := 'CREATE OR REPLACE VIEW shared.cross_client_summary AS '
           || array_to_string(v_parts, ' UNION ALL ');

  EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION shared.refresh_cross_client_summary() IS
  'Rebuilds the cross_client_summary view to union all active client schemas. '
  'Call after provisioning a new client or making schema changes.';

-- ---------------------------------------------------------------------------
-- ENTITLEMENT UTILISATION VIEW
-- Shows for each active entitlement: how much is assigned vs total
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.entitlement_utilisation AS
SELECT
  e.entitlement_id,
  e.csi_number,
  e.product_name,
  e.product_family,
  e.license_metric,
  e.quantity                                    AS total_quantity,
  e.status,
  e.support_expiry,
  e.ula_expiry,
  e.is_ula,
  COUNT(m.client_id)                            AS assigned_client_count,
  SUM(COALESCE(m.allocated_quantity, e.quantity)) AS total_allocated,
  e.quantity - SUM(COALESCE(m.allocated_quantity, e.quantity))
                                                AS unallocated_quantity,
  CASE
    WHEN e.support_expiry < CURRENT_DATE THEN 'expired'
    WHEN e.support_expiry < CURRENT_DATE + INTERVAL '90 days' THEN 'expiring_soon'
    ELSE 'current'
  END                                           AS support_status,
  CASE
    WHEN e.ula_expiry IS NOT NULL AND e.ula_expiry < CURRENT_DATE THEN 'ula_expired'
    WHEN e.ula_expiry IS NOT NULL AND e.ula_expiry < CURRENT_DATE + INTERVAL '180 days' THEN 'ula_expiring'
    ELSE NULL
  END                                           AS ula_status
FROM   shared.license_entitlements e
LEFT   JOIN shared.entitlement_client_map m ON m.entitlement_id = e.entitlement_id
GROUP  BY e.entitlement_id, e.csi_number, e.product_name, e.product_family,
          e.license_metric, e.quantity, e.status, e.support_expiry,
          e.ula_expiry, e.is_ula;

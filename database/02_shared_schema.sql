-- =============================================================================
-- Shared Schema v3 — CSI contract header + line items with pricing
--
-- Data model:
--
--   csi_contracts               (1)  One row per CSI / purchase contract.
--        |                           Holds sharing policy, ownership, dates.
--        |
--   license_entitlement_lines   (*)  One row per product within a CSI.
--        |                           Holds product, metric, quantity, unit price.
--        |
--   csi_client_map              (*)  Which clients may use a given CSI.
--                                    One row per CSI × client combination.
--
-- This replaces the old single-table license_entitlements design.
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

CREATE TYPE shared.sharing_policy AS ENUM
  ('client_locked', 'shareable', 'unassigned');

-- ---------------------------------------------------------------------------
-- CSI CONTRACTS
-- Contract-level header — one row per Oracle CSI or purchase order.
-- Product detail and pricing live in license_entitlement_lines.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.csi_contracts (
  csi_id            SERIAL PRIMARY KEY,
  csi_number        TEXT UNIQUE,
  contract_name     TEXT NOT NULL,
  vendor_reference  TEXT,
  purchase_date     DATE,
  support_start     DATE,
  support_expiry    DATE,
  ula_expiry        DATE,
  is_ula            BOOLEAN NOT NULL DEFAULT FALSE,
  currency          CHAR(3) NOT NULL DEFAULT 'USD',

  sharing_policy    shared.sharing_policy NOT NULL DEFAULT 'unassigned',
  owning_client_id  INTEGER REFERENCES sam_admin.clients (client_id),

  notes             TEXT,
  status            shared.license_status NOT NULL DEFAULT 'active',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_csi_fmt      CHECK (csi_number IS NULL OR csi_number ~ '^\d+$'),
  CONSTRAINT chk_locked_owner CHECK (
    sharing_policy <> 'client_locked' OR owning_client_id IS NOT NULL
  ),
  CONSTRAINT chk_currency     CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE INDEX idx_csi_number ON shared.csi_contracts (csi_number);
CREATE INDEX idx_csi_status ON shared.csi_contracts (status);
CREATE INDEX idx_csi_policy ON shared.csi_contracts (sharing_policy);
CREATE INDEX idx_csi_owner  ON shared.csi_contracts (owning_client_id);

CREATE OR REPLACE FUNCTION shared.touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

CREATE TRIGGER trg_csi_updated
  BEFORE UPDATE ON shared.csi_contracts
  FOR EACH ROW EXECUTE FUNCTION shared.touch_updated_at();

-- ---------------------------------------------------------------------------
-- LICENSE ENTITLEMENT LINES
-- One row per product within a CSI contract.
-- Examples for a single CSI:
--   Line 1: Oracle Database Enterprise Edition  — 50 processor  @ $47,500
--   Line 2: Oracle Diagnostic Pack              — 50 processor  @ $7,500
--   Line 3: Oracle Tuning Pack                  — 50 processor  @ $5,000
--   Line 4: Oracle Partitioning                 — 50 processor  @ $11,500
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.license_entitlement_lines (
  line_id             SERIAL PRIMARY KEY,
  csi_id              INTEGER NOT NULL
                        REFERENCES shared.csi_contracts (csi_id) ON DELETE CASCADE,
  line_number         INTEGER NOT NULL DEFAULT 1,
  product_name        TEXT NOT NULL,
  product_family      shared.product_family NOT NULL DEFAULT 'oracle_database',
  license_metric      shared.license_metric NOT NULL DEFAULT 'processor',
  quantity            NUMERIC(10,2) NOT NULL,

  -- Pricing
  unit_price          NUMERIC(14,4),      -- price per single licence (e.g. per processor licence)
  total_price         NUMERIC(14,2)
                        GENERATED ALWAYS AS (
                          CASE WHEN unit_price IS NOT NULL
                               THEN ROUND(quantity * unit_price, 2)
                               ELSE NULL END
                        ) STORED,
  annual_support_cost NUMERIC(14,2),      -- annual support for this line (often ~22% of total_price)

  notes               TEXT,
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_line_qty   CHECK (quantity >= 0),
  CONSTRAINT chk_line_price CHECK (unit_price IS NULL OR unit_price >= 0),
  UNIQUE (csi_id, line_number)
);

CREATE INDEX idx_lines_csi     ON shared.license_entitlement_lines (csi_id);
CREATE INDEX idx_lines_product ON shared.license_entitlement_lines (product_name);
CREATE INDEX idx_lines_family  ON shared.license_entitlement_lines (product_family);

CREATE TRIGGER trg_line_updated
  BEFORE UPDATE ON shared.license_entitlement_lines
  FOR EACH ROW EXECUTE FUNCTION shared.touch_updated_at();

-- ---------------------------------------------------------------------------
-- CSI → CLIENT MAP
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.csi_client_map (
  map_id             SERIAL PRIMARY KEY,
  csi_id             INTEGER NOT NULL
                       REFERENCES shared.csi_contracts (csi_id) ON DELETE CASCADE,
  client_id          INTEGER NOT NULL
                       REFERENCES sam_admin.clients (client_id) ON DELETE CASCADE,
  allocated_quantity NUMERIC(10,2),
  allocation_notes   TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (csi_id, client_id)
);

CREATE INDEX idx_ccm_csi    ON shared.csi_client_map (csi_id);
CREATE INDEX idx_ccm_client ON shared.csi_client_map (client_id);

-- ---------------------------------------------------------------------------
-- TRIGGER: enforce sharing policy on csi_client_map
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION shared.enforce_csi_sharing_policy()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_policy   shared.sharing_policy;
  v_owner    INTEGER;
  v_existing INTEGER;
BEGIN
  SELECT sharing_policy, owning_client_id
  INTO   v_policy, v_owner
  FROM   shared.csi_contracts
  WHERE  csi_id = NEW.csi_id;

  IF v_policy = 'unassigned' THEN
    RAISE EXCEPTION
      'CSI contract % has sharing_policy = unassigned. '
      'Set policy to client_locked or shareable before assigning to a client.',
      NEW.csi_id;
  END IF;

  IF v_policy = 'client_locked' THEN
    IF NEW.client_id <> v_owner THEN
      RAISE EXCEPTION
        'CSI contract % is client_locked to client_id %. '
        'It cannot be assigned to client_id %.',
        NEW.csi_id, v_owner, NEW.client_id;
    END IF;

    SELECT COUNT(*) INTO v_existing
    FROM   shared.csi_client_map
    WHERE  csi_id  = NEW.csi_id
      AND  map_id <> COALESCE(NEW.map_id, -1);

    IF v_existing > 0 THEN
      RAISE EXCEPTION
        'CSI contract % is client_locked and already has a client assignment.',
        NEW.csi_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_csi_sharing
  BEFORE INSERT OR UPDATE ON shared.csi_client_map
  FOR EACH ROW EXECUTE FUNCTION shared.enforce_csi_sharing_policy();

-- ---------------------------------------------------------------------------
-- ORACLE CORE FACTOR TABLE
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.core_factor_table (
  core_factor_id    SERIAL PRIMARY KEY,
  processor_pattern TEXT NOT NULL,
  core_factor       NUMERIC(4,2) NOT NULL,
  notes             TEXT,
  effective_date    DATE NOT NULL DEFAULT CURRENT_DATE,
  is_current        BOOLEAN NOT NULL DEFAULT TRUE,
  source_url        TEXT,
  CONSTRAINT chk_factor CHECK (core_factor > 0 AND core_factor <= 1)
);

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
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.wls_license_rules (
  rule_id           SERIAL PRIMARY KEY,
  edition_pattern   TEXT NOT NULL,
  metric            shared.license_metric NOT NULL DEFAULT 'processor',
  uses_core_factor  BOOLEAN NOT NULL DEFAULT TRUE,
  notes             TEXT
);

INSERT INTO shared.wls_license_rules (edition_pattern, metric, uses_core_factor, notes) VALUES
  ('%WebLogic Server%',      'processor', TRUE, 'Standard WLS'),
  ('%WebLogic Suite%',       'processor', TRUE, 'WLS Suite — includes Coherence, Tuxedo'),
  ('%Coherence%',            'processor', TRUE, 'Oracle Coherence'),
  ('%SOA Suite%',            'processor', TRUE, 'Oracle SOA Suite'),
  ('%Service Bus%',          'processor', TRUE, 'Oracle Service Bus'),
  ('%Access Manager%',       'processor', TRUE, 'Oracle Access Manager'),
  ('%Identity Governance%',  'processor', TRUE, 'Oracle Identity Governance');

-- ---------------------------------------------------------------------------
-- CROSS-CLIENT SUMMARY VIEW (placeholder — rebuilt by refresh function)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.cross_client_summary AS
SELECT
  NULL::TEXT        AS client_code,  NULL::INTEGER     AS client_id,
  NULL::TEXT        AS hostname,     NULL::TEXT        AS environment,
  NULL::TIMESTAMPTZ AS last_seen,    NULL::INTEGER     AS cpu_sockets,
  NULL::INTEGER     AS total_physical_cores,           NULL::TEXT AS cpu_model,
  NULL::TEXT        AS virt_type,    NULL::BIGINT      AS oracle_instance_count,
  NULL::BIGINT      AS wls_domain_count
WHERE FALSE;

CREATE OR REPLACE FUNCTION shared.refresh_cross_client_summary()
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_client   RECORD;
  v_parts    TEXT[] := '{}';
BEGIN
  FOR v_client IN
    SELECT client_id, client_code, schema_name FROM sam_admin.clients WHERE is_active = TRUE
  LOOP
    v_parts := array_append(v_parts, format(
      $u$SELECT %L::TEXT AS client_code, %s::INTEGER AS client_id,
          s.hostname, s.environment::TEXT, s.last_seen,
          p.cpu_sockets, p.total_physical_cores, p.cpu_model, p.virt_type::TEXT,
          COUNT(DISTINCT i.instance_id) AS oracle_instance_count,
          COUNT(DISTINCT d.domain_id)   AS wls_domain_count
         FROM %I.oracle_servers s
         LEFT JOIN LATERAL (SELECT * FROM %I.oracle_processors op
           WHERE op.server_id = s.server_id ORDER BY op.recorded_at DESC LIMIT 1) p ON TRUE
         LEFT JOIN %I.oracle_instances i ON i.server_id = s.server_id AND i.is_active
         LEFT JOIN %I.wls_domains      d ON d.server_id = s.server_id AND d.is_active
         WHERE s.is_active
         GROUP BY s.server_id, s.hostname, s.environment, s.last_seen,
                  p.cpu_sockets, p.total_physical_cores, p.cpu_model, p.virt_type$u$,
      v_client.client_code, v_client.client_id,
      v_client.schema_name, v_client.schema_name,
      v_client.schema_name, v_client.schema_name
    ));
  END LOOP;

  IF array_length(v_parts, 1) IS NULL THEN RETURN; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW shared.cross_client_summary AS '
          || array_to_string(v_parts, ' UNION ALL ');
END;
$$;

-- ---------------------------------------------------------------------------
-- CSI CONTRACT SUMMARY VIEW
-- One row per CSI contract — line item totals rolled up.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.csi_contract_summary AS
WITH line_totals AS (
  SELECT
    csi_id,
    COUNT(*)                                        AS line_count,
    SUM(quantity)                                   AS total_licences,
    SUM(total_price)                                AS total_licence_cost,
    SUM(annual_support_cost)                        AS total_annual_support,
    COALESCE(SUM(total_price), 0)
      + COALESCE(SUM(annual_support_cost), 0)       AS total_contract_value,
    STRING_AGG(DISTINCT product_family::TEXT, ', '
               ORDER BY product_family::TEXT)       AS product_families,
    STRING_AGG(product_name, ' | '
               ORDER BY line_number)                AS product_summary
  FROM   shared.license_entitlement_lines
  WHERE  is_active = TRUE
  GROUP  BY csi_id
),
client_agg AS (
  SELECT
    csi_id,
    COUNT(m.client_id)                                AS assigned_client_count,
    STRING_AGG(c.client_code, ', '
               ORDER BY c.client_code)              AS assigned_clients
  FROM   shared.csi_client_map m
  JOIN   sam_admin.clients c ON c.client_id = m.client_id
  GROUP  BY csi_id
)
SELECT
  cs.csi_id,
  cs.csi_number,
  cs.contract_name,
  cs.vendor_reference,
  cs.currency,
  cs.purchase_date,
  cs.support_start,
  cs.support_expiry,
  cs.ula_expiry,
  cs.is_ula,
  cs.sharing_policy,
  cs.status,
  cs.notes,
  oc.client_code                                    AS owning_client,
  oc.client_name                                    AS owning_client_name,
  COALESCE(lt.line_count, 0)                        AS line_count,
  COALESCE(lt.total_licences, 0)                    AS total_licences,
  lt.total_licence_cost,
  lt.total_annual_support,
  lt.total_contract_value,
  lt.product_families,
  lt.product_summary,
  COALESCE(ca.assigned_client_count, 0)             AS assigned_client_count,
  COALESCE(ca.assigned_clients, '—')                AS assigned_clients,
  CASE WHEN cs.sharing_policy = 'shareable'
       THEN TRUE ELSE FALSE END                     AS can_share,
  CASE
    WHEN cs.support_expiry IS NULL                              THEN 'no_expiry_set'
    WHEN cs.support_expiry < CURRENT_DATE                       THEN 'expired'
    WHEN cs.support_expiry < CURRENT_DATE + INTERVAL '90 days' THEN 'expiring_soon'
    ELSE 'current'
  END                                               AS support_status,
  CASE
    WHEN cs.ula_expiry IS NULL                                       THEN NULL
    WHEN cs.ula_expiry < CURRENT_DATE                                THEN 'ula_expired'
    WHEN cs.ula_expiry < CURRENT_DATE + INTERVAL '180 days'         THEN 'ula_expiring'
    ELSE 'ula_current'
  END                                               AS ula_status,
  CASE
    WHEN cs.sharing_policy = 'unassigned'            THEN 'NEEDS POLICY'
    WHEN COALESCE(ca.assigned_client_count, 0) = 0   THEN 'NEEDS ASSIGNMENT'
    ELSE 'ASSIGNED'
  END                                               AS allocation_status
FROM   shared.csi_contracts         cs
LEFT   JOIN line_totals              lt ON lt.csi_id = cs.csi_id
LEFT   JOIN client_agg               ca ON ca.csi_id = cs.csi_id
LEFT   JOIN sam_admin.clients        oc ON oc.client_id = cs.owning_client_id;

-- ---------------------------------------------------------------------------
-- LINE ITEM DETAIL VIEW
-- One row per product line — joined to contract header.
-- Primary view for per-product and per-seat cost analysis in Power BI.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.entitlement_line_detail AS
SELECT
  l.line_id,
  l.csi_id,
  cs.csi_number,
  cs.contract_name,
  cs.currency,
  cs.purchase_date,
  cs.support_expiry,
  cs.sharing_policy,
  cs.status                             AS contract_status,
  oc.client_code                        AS owning_client,
  l.line_number,
  l.product_name,
  l.product_family,
  l.license_metric,
  l.quantity,
  l.unit_price,
  l.total_price,
  l.annual_support_cost,
  COALESCE(l.total_price, 0)
    + COALESCE(l.annual_support_cost, 0)  AS total_line_cost,
  CASE
    WHEN l.quantity > 0 AND l.unit_price IS NOT NULL THEN
      ROUND(
        (COALESCE(l.total_price, 0) + COALESCE(l.annual_support_cost, 0))
        / l.quantity, 2)
    ELSE NULL
  END                                   AS cost_per_licence_incl_support,
  l.notes                               AS line_notes,
  l.is_active
FROM   shared.license_entitlement_lines  l
JOIN   shared.csi_contracts              cs ON cs.csi_id = l.csi_id
LEFT   JOIN sam_admin.clients            oc ON oc.client_id = cs.owning_client_id
ORDER  BY cs.csi_number, l.line_number;

-- ---------------------------------------------------------------------------
-- ENTITLEMENTS BY CLIENT VIEW
-- Used by client-schema license_position views.
-- Returns one row per product line per client, with pro-rated quantity if
-- the client has an allocated_quantity split on the contract.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.entitlements_by_client AS
WITH contract_totals AS (
  SELECT csi_id, SUM(quantity) AS contract_total_qty
  FROM   shared.license_entitlement_lines
  WHERE  is_active = TRUE
  GROUP  BY csi_id
)
SELECT
  l.line_id,
  l.csi_id,
  cs.csi_number,
  cs.contract_name,
  cs.sharing_policy,
  cs.owning_client_id,
  cs.support_expiry,
  cs.ula_expiry,
  cs.is_ula,
  cs.status,
  cs.currency,
  l.product_name,
  l.product_family,
  l.license_metric,
  l.quantity                              AS total_quantity,
  -- Pro-rate the line quantity by the client's allocated share of the contract
  CASE
    WHEN m.allocated_quantity IS NULL THEN l.quantity
    ELSE ROUND(
      l.quantity
      * m.allocated_quantity
      / NULLIF(ct.contract_total_qty, 0),
      2)
  END                                     AS client_quantity,
  l.unit_price,
  l.total_price,
  l.annual_support_cost,
  m.allocated_quantity                    AS map_allocated_quantity,
  c.client_id,
  c.client_code,
  c.client_name,
  c.schema_name
FROM   shared.csi_contracts              cs
JOIN   shared.csi_client_map             m  ON m.csi_id    = cs.csi_id
JOIN   sam_admin.clients                 c  ON c.client_id = m.client_id
JOIN   shared.license_entitlement_lines  l  ON l.csi_id    = cs.csi_id AND l.is_active
JOIN   contract_totals                   ct ON ct.csi_id   = cs.csi_id
WHERE  c.is_active = TRUE;

-- ---------------------------------------------------------------------------
-- UNASSIGNED / ACTION-REQUIRED VIEW
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.unassigned_licences AS
SELECT * FROM shared.csi_contract_summary
WHERE  allocation_status IN ('NEEDS POLICY', 'NEEDS ASSIGNMENT')
ORDER  BY
  CASE allocation_status WHEN 'NEEDS POLICY' THEN 1 ELSE 2 END,
  product_families, contract_name;

-- Alias kept for backward compatibility with existing Power BI reports
CREATE OR REPLACE VIEW shared.entitlement_utilisation AS
SELECT * FROM shared.csi_contract_summary;

-- ---------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- ---------------------------------------------------------------------------

-- add_csi(): create a contract header
CREATE OR REPLACE FUNCTION shared.add_csi(
  p_contract_name   TEXT,
  p_csi_number      TEXT                  DEFAULT NULL,
  p_vendor_ref      TEXT                  DEFAULT NULL,
  p_purchase_date   DATE                  DEFAULT NULL,
  p_support_start   DATE                  DEFAULT NULL,
  p_support_expiry  DATE                  DEFAULT NULL,
  p_ula_expiry      DATE                  DEFAULT NULL,
  p_is_ula          BOOLEAN               DEFAULT FALSE,
  p_currency        CHAR(3)               DEFAULT 'USD',
  p_notes           TEXT                  DEFAULT NULL,
  p_locked_to       TEXT                  DEFAULT NULL,
  p_policy          shared.sharing_policy DEFAULT 'unassigned'
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
  v_client_id INTEGER;
  v_policy    shared.sharing_policy;
  v_new_id    INTEGER;
BEGIN
  IF p_locked_to IS NOT NULL THEN
    SELECT client_id INTO v_client_id FROM sam_admin.clients
    WHERE  client_code = p_locked_to AND is_active = TRUE;
    IF v_client_id IS NULL THEN
      RAISE EXCEPTION 'p_locked_to: client code "%" not found or inactive.', p_locked_to;
    END IF;
    v_policy := 'client_locked';
  ELSE
    v_policy := p_policy;
  END IF;

  IF v_policy = 'client_locked' AND v_client_id IS NULL THEN
    RAISE EXCEPTION 'sharing_policy = client_locked requires p_locked_to.';
  END IF;

  INSERT INTO shared.csi_contracts (
    csi_number, contract_name, vendor_reference,
    purchase_date, support_start, support_expiry, ula_expiry,
    is_ula, currency, notes, sharing_policy, owning_client_id
  ) VALUES (
    p_csi_number, p_contract_name, p_vendor_ref,
    p_purchase_date, p_support_start, p_support_expiry, p_ula_expiry,
    p_is_ula, p_currency, p_notes, v_policy, v_client_id
  ) RETURNING csi_id INTO v_new_id;

  IF v_policy = 'client_locked' THEN
    INSERT INTO shared.csi_client_map (csi_id, client_id) VALUES (v_new_id, v_client_id);
  END IF;

  RETURN v_new_id;
END;
$$;

-- add_csi_line(): add a product line to an existing contract
-- Returns line_id.
--
-- Example — a CSI with four product lines:
--   DO $$
--   DECLARE v INTEGER;
--   BEGIN
--     v := shared.add_csi('Acme Oracle 2023', p_csi_number => '12345678',
--            p_locked_to => 'acme', p_support_expiry => '2026-01-01');
--     PERFORM shared.add_csi_line(v, 'Oracle Database Enterprise Edition',
--               'oracle_database', 'processor', 50, 47500.00, 10450.00);
--     PERFORM shared.add_csi_line(v, 'Oracle Diagnostic Pack',
--               'oracle_database', 'processor', 50,  7500.00,  1650.00);
--     PERFORM shared.add_csi_line(v, 'Oracle Tuning Pack',
--               'oracle_database', 'processor', 50,  5000.00,  1100.00);
--     PERFORM shared.add_csi_line(v, 'Oracle Partitioning',
--               'oracle_database', 'processor', 50, 11500.00,  2530.00);
--   END $$;
CREATE OR REPLACE FUNCTION shared.add_csi_line(
  p_csi_id         INTEGER,
  p_product_name   TEXT,
  p_product_family shared.product_family  DEFAULT 'oracle_database',
  p_metric         shared.license_metric  DEFAULT 'processor',
  p_quantity       NUMERIC                DEFAULT 1,
  p_unit_price     NUMERIC                DEFAULT NULL,
  p_annual_support NUMERIC                DEFAULT NULL,
  p_notes          TEXT                   DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
  v_next_line INTEGER;
  v_new_id    INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM shared.csi_contracts WHERE csi_id = p_csi_id) THEN
    RAISE EXCEPTION 'CSI contract % not found.', p_csi_id;
  END IF;

  SELECT COALESCE(MAX(line_number), 0) + 1 INTO v_next_line
  FROM   shared.license_entitlement_lines WHERE csi_id = p_csi_id;

  INSERT INTO shared.license_entitlement_lines (
    csi_id, line_number, product_name, product_family,
    license_metric, quantity, unit_price, annual_support_cost, notes
  ) VALUES (
    p_csi_id, v_next_line, p_product_name, p_product_family,
    p_metric, p_quantity, p_unit_price, p_annual_support, p_notes
  ) RETURNING line_id INTO v_new_id;

  RETURN v_new_id;
END;
$$;

-- assign_csi_to_client(): assign a contract to a client by client_code
CREATE OR REPLACE FUNCTION shared.assign_csi_to_client(
  p_csi_id       INTEGER,
  p_client_code  TEXT,
  p_policy       shared.sharing_policy,
  p_quantity     NUMERIC DEFAULT NULL,
  p_notes        TEXT    DEFAULT NULL
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_client_id      INTEGER;
  v_current_policy shared.sharing_policy;
BEGIN
  SELECT client_id INTO v_client_id FROM sam_admin.clients
  WHERE  client_code = p_client_code AND is_active = TRUE;
  IF v_client_id IS NULL THEN
    RAISE EXCEPTION 'Client code "%" not found or inactive.', p_client_code;
  END IF;

  SELECT sharing_policy INTO v_current_policy FROM shared.csi_contracts
  WHERE  csi_id = p_csi_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CSI contract % not found.', p_csi_id;
  END IF;

  IF v_current_policy = 'unassigned' THEN
    UPDATE shared.csi_contracts
    SET    sharing_policy   = p_policy,
           owning_client_id = CASE WHEN p_policy = 'client_locked'
                                   THEN v_client_id ELSE owning_client_id END
    WHERE  csi_id = p_csi_id;
  ELSIF v_current_policy <> p_policy THEN
    RAISE EXCEPTION
      'CSI contract % already has sharing_policy = %. Cannot change to % here.',
      p_csi_id, v_current_policy, p_policy;
  END IF;

  INSERT INTO shared.csi_client_map (csi_id, client_id, allocated_quantity, allocation_notes)
  VALUES (p_csi_id, v_client_id, p_quantity, p_notes)
  ON CONFLICT (csi_id, client_id) DO UPDATE
    SET allocated_quantity = EXCLUDED.allocated_quantity,
        allocation_notes   = EXCLUDED.allocation_notes;

  RETURN format('CSI contract %s assigned to client %s (policy: %s).',
                p_csi_id, p_client_code, p_policy);
END;
$$;

-- set_csi_owner(): declare or change the owning client by client_code
CREATE OR REPLACE FUNCTION shared.set_csi_owner(
  p_csi_id      INTEGER,
  p_client_code TEXT,
  p_lock        BOOLEAN DEFAULT FALSE
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_client_id      INTEGER;
  v_current_policy shared.sharing_policy;
BEGIN
  IF p_client_code IS NOT NULL THEN
    SELECT client_id INTO v_client_id FROM sam_admin.clients
    WHERE  client_code = p_client_code AND is_active = TRUE;
    IF v_client_id IS NULL THEN
      RAISE EXCEPTION 'Client code "%" not found or inactive.', p_client_code;
    END IF;
  END IF;

  SELECT sharing_policy INTO v_current_policy FROM shared.csi_contracts
  WHERE  csi_id = p_csi_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CSI contract % not found.', p_csi_id;
  END IF;

  IF p_client_code IS NULL AND v_current_policy = 'client_locked' THEN
    RAISE EXCEPTION
      'Cannot clear owning client on CSI % because sharing_policy = client_locked. '
      'Change policy to shareable first.', p_csi_id;
  END IF;

  UPDATE shared.csi_contracts
  SET    owning_client_id = v_client_id,
         sharing_policy   = CASE WHEN p_lock
                                 THEN 'client_locked'::shared.sharing_policy
                                 ELSE sharing_policy END
  WHERE  csi_id = p_csi_id;

  RETURN format('CSI contract %s: owner set to %s%s.',
    p_csi_id,
    COALESCE(p_client_code, 'NULL (cleared)'),
    CASE WHEN p_lock THEN ', locked' ELSE '' END);
END;
$$;

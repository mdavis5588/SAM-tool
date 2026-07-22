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

  br_number         TEXT,
  p2p_number        TEXT,
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

DROP TRIGGER IF EXISTS trg_csi_updated ON shared.csi_contracts;
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

DROP TRIGGER IF EXISTS trg_line_updated ON shared.license_entitlement_lines;
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

DROP TRIGGER IF EXISTS trg_enforce_csi_sharing ON shared.csi_client_map;
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
-- ORACLE LICENSED OPTIONS
-- Reference table: which v$option names require a separate Oracle licence.
-- Joined by the license_position view to surface option lines automatically.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.oracle_licensed_options (
  option_id       SERIAL PRIMARY KEY,
  option_name     TEXT NOT NULL UNIQUE,   -- matches v$option / oracle_options.option_name
  display_name    TEXT NOT NULL,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  notes           TEXT
);

INSERT INTO shared.oracle_licensed_options (option_name, display_name, notes) VALUES
  ('Partitioning',              'Oracle Partitioning',              'Separate EE option licence required'),
  ('Advanced Security',         'Oracle Advanced Security',         'TDE and network encryption'),
  ('Advanced Compression',      'Oracle Advanced Compression',      NULL),
  ('Diagnostics Pack',          'Oracle Diagnostics Pack',          'Includes AWR, ADDM, ASH'),
  ('Tuning Pack',               'Oracle Tuning Pack',               'Requires Diagnostics Pack'),
  ('Database Vault',            'Oracle Database Vault',            NULL),
  ('Label Security',            'Oracle Label Security',            NULL),
  ('Real Application Clusters', 'Oracle Real Application Clusters', 'Per-node licence required'),
  ('Active Data Guard',         'Oracle Active Data Guard',         'Standby read-only access'),
  ('Multitenant',               'Oracle Multitenant',               'Required when >1 PDB per CDB'),
  ('Database In-Memory',        'Oracle Database In-Memory',        NULL),
  ('Spatial and Graph',         'Oracle Spatial and Graph',         NULL),
  ('OLAP',                      'Oracle OLAP',                      NULL),
  ('Data Mining',               'Oracle Data Mining',               'In-database machine learning (OAA)')
ON CONFLICT (option_name) DO NOTHING;

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
-- JAVA SE LICENSE EDITIONS
-- Reference table for determining whether a discovered Java installation
-- requires an Oracle licence.  Oracle changed its Java licensing model in
-- January 2019 (JDK 8) and again in September 2021 / January 2023.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.java_license_editions (
  edition_id        SERIAL PRIMARY KEY,
  edition_name      TEXT NOT NULL UNIQUE,
  requires_licence  BOOLEAN NOT NULL DEFAULT FALSE,
  licence_metric    TEXT,
  notes             TEXT
);

INSERT INTO shared.java_license_editions
  (edition_name, requires_licence, licence_metric, notes) VALUES
  ('Oracle JDK 8 (pre-Jan-2019)',    FALSE, NULL,       'Free for commercial use until Jan 2019 — no Oracle licence required'),
  ('Oracle JDK 8 (post-Jan-2019)',   TRUE,  'named_user','Commercial use requires Oracle Java SE Subscription since Jan 2019'),
  ('Oracle JDK 11 / 17 (2021-2022)', TRUE,  'employee',  'Employee-count metric: Oracle Java SE Universal Subscription from Sept 2021'),
  ('Oracle JDK 17+ (post-Jan-2023)', TRUE,  'employee',  'Oracle Java SE Universal Subscription: covers all employees regardless of JDK usage'),
  ('Oracle JDK 21+ LTS',            TRUE,  'employee',  'Long-term support release under employee-count subscription model'),
  ('Oracle GraalVM Enterprise',      TRUE,  'processor', 'Processor-licensed; included with Oracle Java SE Subscription'),
  ('OpenJDK',                        FALSE, NULL,        'Free — no Oracle licence required'),
  ('Eclipse Temurin / AdoptOpenJDK', FALSE, NULL,        'Free Adoptium build of OpenJDK — no Oracle licence required'),
  ('Amazon Corretto',                FALSE, NULL,        'Free AWS build of OpenJDK — no Oracle licence required'),
  ('Microsoft Build of OpenJDK',     FALSE, NULL,        'Free Microsoft build of OpenJDK — no Oracle licence required'),
  ('Azul Zulu',                      FALSE, NULL,        'Free community build; Azul Platform Core/Prime require separate Azul subscription'),
  ('Oracle JRE 8 (desktop only)',    FALSE, NULL,        'JRE-only personal desktop use — free under NFTC; review terms carefully')
ON CONFLICT (edition_name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- MYSQL LICENSE EDITIONS
-- Reference table for MySQL edition classification.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.mysql_license_editions (
  edition_id        SERIAL PRIMARY KEY,
  edition_name      TEXT NOT NULL UNIQUE,
  requires_licence  BOOLEAN NOT NULL DEFAULT FALSE,
  licence_metric    TEXT,
  notes             TEXT
);

INSERT INTO shared.mysql_license_editions
  (edition_name, requires_licence, licence_metric, notes) VALUES
  ('MySQL Community Server', FALSE, NULL,     'GPL — free for open source; proprietary redistribution requires commercial licence'),
  ('MySQL Enterprise',       TRUE,  'server', 'Annual per-server subscription; includes Enterprise features and Oracle support'),
  ('MySQL Cluster CGE',      TRUE,  'server', 'Annual per-data-node subscription for NDB Cluster'),
  ('MySQL Standard',         TRUE,  'server', 'Legacy edition — discontinued; verify against existing contracts'),
  ('MySQL Classic',          TRUE,  'server', 'Legacy edition — discontinued; verify against existing contracts'),
  ('MariaDB',                FALSE, NULL,     'Open-source MySQL fork — no Oracle licence required')
ON CONFLICT (edition_name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- ULA CERTIFICATION TRACKING
-- One row per product per client per ULA contract.
-- Used to track progress toward ULA certification, which must be completed
-- before the ULA expiry date to lock in deployment counts as perpetual licences.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.ula_certifications (
  cert_id                SERIAL PRIMARY KEY,
  csi_id                 INTEGER NOT NULL REFERENCES shared.csi_contracts (csi_id),
  client_id              INTEGER NOT NULL REFERENCES sam_admin.clients (client_id),
  product_name           TEXT NOT NULL,
  ula_start_date         DATE NOT NULL,
  ula_expiry_date        DATE NOT NULL,
  deployment_at_start    INTEGER,
  current_deployment     INTEGER,
  declared_quantity      INTEGER,
  certification_date     DATE,
  certified_by           TEXT,
  certified_at           TIMESTAMPTZ,
  status                 TEXT NOT NULL DEFAULT 'pending'
                           CHECK (status IN ('pending','certified','overdue','at_risk')),
  notes                  TEXT,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_ula_cert_dates CHECK (ula_expiry_date > ula_start_date),
  UNIQUE (csi_id, client_id, product_name)
);

CREATE INDEX idx_ula_csi    ON shared.ula_certifications (csi_id);
CREATE INDEX idx_ula_client ON shared.ula_certifications (client_id);
CREATE INDEX idx_ula_status ON shared.ula_certifications (status);
CREATE INDEX idx_ula_expiry ON shared.ula_certifications (ula_expiry_date);

DROP TRIGGER IF EXISTS trg_ula_updated ON shared.ula_certifications;
CREATE TRIGGER trg_ula_updated
  BEFORE UPDATE ON shared.ula_certifications
  FOR EACH ROW EXECUTE FUNCTION shared.touch_updated_at();

-- ---------------------------------------------------------------------------
-- ULA CERTIFICATION STATUS VIEW
-- Shows health of each ULA: days to expiry, growth since start, risk level.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.ula_certification_status AS
SELECT
  uc.cert_id,
  uc.csi_id,
  cs.csi_number,
  cs.contract_name,
  c.client_code,
  c.client_name,
  uc.product_name,
  uc.ula_start_date,
  uc.ula_expiry_date,
  (uc.ula_expiry_date - CURRENT_DATE)::INTEGER   AS days_until_expiry,
  uc.deployment_at_start,
  uc.current_deployment,
  CASE
    WHEN uc.current_deployment IS NOT NULL AND uc.deployment_at_start IS NOT NULL
    THEN uc.current_deployment - uc.deployment_at_start
    ELSE NULL
  END                                            AS deployment_growth,
  uc.declared_quantity,
  uc.certification_date,
  uc.certified_by,
  uc.status,
  uc.notes,
  CASE
    WHEN uc.status = 'certified'                                         THEN 'CERTIFIED'
    WHEN uc.ula_expiry_date < CURRENT_DATE                               THEN 'OVERDUE'
    WHEN uc.ula_expiry_date < CURRENT_DATE + INTERVAL '60 days'         THEN 'EXPIRING_SOON'
    WHEN uc.ula_expiry_date < CURRENT_DATE + INTERVAL '180 days'        THEN 'AT_RISK'
    ELSE 'ON_TRACK'
  END                                            AS ula_health,
  COALESCE(uc.current_deployment, 0)             AS estimated_certifiable_quantity
FROM shared.ula_certifications uc
JOIN shared.csi_contracts       cs ON cs.csi_id   = uc.csi_id
JOIN sam_admin.clients          c  ON c.client_id = uc.client_id
ORDER BY uc.ula_expiry_date ASC;

-- ---------------------------------------------------------------------------
-- COST AND RENEWAL FORECASTING VIEW
-- Projects annual support costs and surfaces contracts by renewal urgency.
-- Support cost = stated annual_support_cost or 22% of licence cost if unset.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.cost_renewal_forecast AS
WITH support_rollup AS (
  SELECT
    l.csi_id,
    SUM(l.total_price)                                                    AS total_licence_cost,
    SUM(l.annual_support_cost)                                            AS stated_annual_support,
    CASE
      WHEN SUM(l.annual_support_cost) IS NOT NULL
      THEN SUM(l.annual_support_cost)
      ELSE ROUND(SUM(COALESCE(l.total_price, 0)) * 0.22, 2)
    END                                                                   AS effective_annual_support
  FROM shared.license_entitlement_lines l
  WHERE l.is_active = TRUE
  GROUP BY l.csi_id
)
SELECT
  cs.csi_id,
  cs.csi_number,
  cs.contract_name,
  cs.currency,
  cs.purchase_date,
  cs.support_start,
  cs.support_expiry,
  cs.is_ula,
  cs.ula_expiry,
  cs.status,
  cs.sharing_policy,
  oc.client_code                                                          AS owning_client,
  sr.total_licence_cost,
  sr.stated_annual_support,
  sr.effective_annual_support,
  -- Years of active support remaining
  CASE
    WHEN cs.support_expiry IS NULL THEN NULL
    ELSE GREATEST(0, ROUND(
      (cs.support_expiry - CURRENT_DATE)::NUMERIC / 365.25, 1
    ))
  END                                                                     AS support_years_remaining,
  -- Support cost projections
  ROUND(sr.effective_annual_support * 1, 2)                              AS forecast_1yr_support,
  ROUND(sr.effective_annual_support * 2, 2)                              AS forecast_2yr_support,
  ROUND(sr.effective_annual_support * 3, 2)                              AS forecast_3yr_support,
  -- Total cost of ownership (licence + N years support)
  COALESCE(sr.total_licence_cost, 0)
    + COALESCE(sr.effective_annual_support, 0)                           AS tco_1yr,
  COALESCE(sr.total_licence_cost, 0)
    + COALESCE(sr.effective_annual_support * 3, 0)                       AS tco_3yr,
  -- Renewal urgency classification
  CASE
    WHEN cs.support_expiry IS NULL                               THEN 'NO_EXPIRY_SET'
    WHEN cs.support_expiry < CURRENT_DATE                        THEN 'EXPIRED'
    WHEN cs.support_expiry < CURRENT_DATE + INTERVAL '30 days'  THEN 'RENEW_NOW'
    WHEN cs.support_expiry < CURRENT_DATE + INTERVAL '90 days'  THEN 'URGENT'
    WHEN cs.support_expiry < CURRENT_DATE + INTERVAL '180 days' THEN 'DUE_SOON'
    ELSE 'CURRENT'
  END                                                                     AS renewal_urgency,
  (cs.support_expiry - CURRENT_DATE)::INTEGER                            AS days_until_renewal
FROM shared.csi_contracts       cs
LEFT JOIN support_rollup        sr ON sr.csi_id        = cs.csi_id
LEFT JOIN sam_admin.clients     oc ON oc.client_id     = cs.owning_client_id
ORDER BY
  CASE
    WHEN cs.support_expiry IS NULL THEN 9999999
    ELSE (cs.support_expiry - CURRENT_DATE)
  END ASC;

-- ---------------------------------------------------------------------------
-- CROSS-CLIENT COMPLIANCE ALERTS
-- Returns all actionable alerts across every client:
--   - CSI contracts expiring within 90 days
--   - ULA contracts expiring within 180 days
--   - Unacknowledged HIGH severity changelog entries older than 7 days
--   - CSI contracts with no policy or client assignment
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION shared.get_compliance_alerts()
RETURNS TABLE (
  alert_type    TEXT,
  severity      TEXT,
  client_code   TEXT,
  client_name   TEXT,
  object_name   TEXT,
  description   TEXT,
  days_until    INTEGER,
  action_needed TEXT
) LANGUAGE plpgsql AS $$
DECLARE
  v_client RECORD;
  v_sql    TEXT;
  v_row    RECORD;
BEGIN

  -- Alert: CSI support contracts expiring within 90 days
  FOR v_row IN
    SELECT cs.csi_number, cs.contract_name,
           c.client_code, c.client_name,
           (cs.support_expiry - CURRENT_DATE)::INTEGER AS days_left,
           cs.support_expiry
    FROM   shared.csi_contracts   cs
    JOIN   shared.csi_client_map  m  ON m.csi_id    = cs.csi_id
    JOIN   sam_admin.clients      c  ON c.client_id = m.client_id
    WHERE  cs.support_expiry IS NOT NULL
      AND  cs.support_expiry >= CURRENT_DATE
      AND  cs.support_expiry <  CURRENT_DATE + INTERVAL '90 days'
      AND  cs.status = 'active'
  LOOP
    alert_type    := 'CSI_EXPIRING';
    severity      := CASE WHEN v_row.days_left <= 30 THEN 'HIGH' ELSE 'MEDIUM' END;
    client_code   := v_row.client_code;
    client_name   := v_row.client_name;
    object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
    description   := 'Support contract expires in ' || v_row.days_left
                     || ' days (' || v_row.support_expiry || ')';
    days_until    := v_row.days_left;
    action_needed := 'Initiate renewal with Oracle LMS / reseller before expiry';
    RETURN NEXT;
  END LOOP;

  -- Alert: ULA contracts expiring within 180 days
  FOR v_row IN
    SELECT cs.csi_number, cs.contract_name,
           c.client_code, c.client_name,
           cs.ula_expiry,
           (cs.ula_expiry - CURRENT_DATE)::INTEGER AS days_left
    FROM   shared.csi_contracts   cs
    JOIN   shared.csi_client_map  m  ON m.csi_id    = cs.csi_id
    JOIN   sam_admin.clients      c  ON c.client_id = m.client_id
    WHERE  cs.is_ula = TRUE
      AND  cs.ula_expiry IS NOT NULL
      AND  cs.ula_expiry >= CURRENT_DATE
      AND  cs.ula_expiry <  CURRENT_DATE + INTERVAL '180 days'
  LOOP
    alert_type    := 'ULA_EXPIRING';
    severity      := CASE WHEN v_row.days_left <= 60 THEN 'HIGH' ELSE 'MEDIUM' END;
    client_code   := v_row.client_code;
    client_name   := v_row.client_name;
    object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
    description   := 'ULA expires in ' || v_row.days_left
                     || ' days. Certification must be completed before '
                     || v_row.ula_expiry;
    days_until    := v_row.days_left;
    action_needed := 'Run full deployment count and initiate ULA certification with Oracle';
    RETURN NEXT;
  END LOOP;

  -- Alert: unacknowledged HIGH severity changelog entries older than 7 days
  FOR v_client IN
    SELECT client_code, schema_name FROM sam_admin.clients WHERE is_active = TRUE
  LOOP
    BEGIN
      v_sql := format(
        $q$SELECT hostname, change_category, object_name, detected_at,
                  EXTRACT(EPOCH FROM (NOW() - detected_at)) / 86400 AS days_old
           FROM %I.discovery_changelog
           WHERE severity = 'HIGH' AND NOT acknowledged
             AND detected_at < NOW() - INTERVAL '7 days'$q$,
        v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'STALE_HIGH_CHANGE';
        severity      := 'HIGH';
        client_code   := v_client.client_code;
        client_name   := (SELECT c.client_name FROM sam_admin.clients c
                          WHERE  c.client_code = v_client.client_code);
        object_name   := v_row.hostname || ': ' || v_row.object_name;
        description   := 'Unacknowledged HIGH severity change ('
                         || v_row.change_category || ') detected '
                         || ROUND(v_row.days_old) || ' days ago';
        days_until    := NULL;
        action_needed := 'Acknowledge in discovery_changelog; update server_csi_map if licence impact is confirmed';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;

  -- Alert: licences with no policy or no client assignment
  FOR v_row IN
    SELECT csi_number, contract_name, allocation_status, product_families
    FROM   shared.unassigned_licences
  LOOP
    alert_type    := 'UNASSIGNED_LICENCE';
    severity      := 'MEDIUM';
    client_code   := NULL;
    client_name   := NULL;
    object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
    description   := v_row.allocation_status || ': '
                     || COALESCE(v_row.product_families, 'unknown product');
    days_until    := NULL;
    action_needed := CASE v_row.allocation_status
      WHEN 'NEEDS POLICY'     THEN 'Set sharing_policy via shared.set_csi_owner() or shared.assign_csi_to_client()'
      WHEN 'NEEDS ASSIGNMENT' THEN 'Assign this CSI to a client via shared.assign_csi_to_client()'
      ELSE 'Review and assign'
    END;
    RETURN NEXT;
  END LOOP;

END;
$$;

-- Convenience view — materialises alerts as a plain table for Power BI
CREATE OR REPLACE VIEW shared.compliance_alerts AS
SELECT * FROM shared.get_compliance_alerts();

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
    m.csi_id,
    COUNT(m.client_id)                              AS assigned_client_count,
    STRING_AGG(c.client_code, ', '
               ORDER BY c.client_code)              AS assigned_clients
  FROM   shared.csi_client_map m
  JOIN   sam_admin.clients c ON c.client_id = m.client_id
  GROUP  BY m.csi_id
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
DROP VIEW IF EXISTS shared.entitlement_line_detail CASCADE;
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
  END                                   AS cost_per_license_incl_support,
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

-- ---------------------------------------------------------------------------
-- CPU CORE FACTOR LOOKUP FUNCTION
-- Returns the Oracle-specified core factor for a given CPU model string by
-- matching against core_factor_table patterns (most-specific match wins).
-- Returns NULL when the CPU model is unrecognised — this should trigger an alert.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION shared.cpu_core_factor_lookup(p_cpu_model TEXT)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT core_factor
  FROM   shared.core_factor_table
  WHERE  UPPER(p_cpu_model) LIKE UPPER(processor_pattern)
    AND  is_current = TRUE
  ORDER  BY LENGTH(processor_pattern) DESC   -- longest (most specific) pattern wins
  LIMIT  1;
$$;

-- ---------------------------------------------------------------------------
-- UPDATED COMPLIANCE ALERTS — replaces the version in get_compliance_alerts()
-- Adds: SE2 socket violations, SE2 RAC cluster size violations,
--       unrecognised CPU model alerts, VMware cluster exposure warnings.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION shared.get_compliance_alerts()
RETURNS TABLE (
  alert_type    TEXT,
  severity      TEXT,
  client_code   TEXT,
  client_name   TEXT,
  object_name   TEXT,
  description   TEXT,
  days_until    INTEGER,
  action_needed TEXT
) LANGUAGE plpgsql AS $$
DECLARE
  v_client RECORD;
  v_sql    TEXT;
  v_row    RECORD;
BEGIN

  -- Alert: CSI support contracts expiring within 90 days
  FOR v_row IN
    SELECT cs.csi_number, cs.contract_name,
           c.client_code, c.client_name,
           (cs.support_expiry - CURRENT_DATE)::INTEGER AS days_left,
           cs.support_expiry
    FROM   shared.csi_contracts   cs
    JOIN   shared.csi_client_map  m  ON m.csi_id    = cs.csi_id
    JOIN   sam_admin.clients      c  ON c.client_id = m.client_id
    WHERE  cs.support_expiry IS NOT NULL
      AND  cs.support_expiry >= CURRENT_DATE
      AND  cs.support_expiry <  CURRENT_DATE + INTERVAL '90 days'
      AND  cs.status = 'active'
  LOOP
    alert_type    := 'CSI_EXPIRING';
    severity      := CASE WHEN v_row.days_left <= 30 THEN 'HIGH' ELSE 'MEDIUM' END;
    client_code   := v_row.client_code;
    client_name   := v_row.client_name;
    object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
    description   := 'Support contract expires in ' || v_row.days_left
                     || ' days (' || v_row.support_expiry || ')';
    days_until    := v_row.days_left;
    action_needed := 'Initiate renewal with Oracle LMS / reseller before expiry';
    RETURN NEXT;
  END LOOP;

  -- Alert: ULA contracts expiring within 180 days
  FOR v_row IN
    SELECT cs.csi_number, cs.contract_name,
           c.client_code, c.client_name,
           cs.ula_expiry,
           (cs.ula_expiry - CURRENT_DATE)::INTEGER AS days_left
    FROM   shared.csi_contracts   cs
    JOIN   shared.csi_client_map  m  ON m.csi_id    = cs.csi_id
    JOIN   sam_admin.clients      c  ON c.client_id = m.client_id
    WHERE  cs.is_ula = TRUE
      AND  cs.ula_expiry IS NOT NULL
      AND  cs.ula_expiry >= CURRENT_DATE
      AND  cs.ula_expiry <  CURRENT_DATE + INTERVAL '180 days'
  LOOP
    alert_type    := 'ULA_EXPIRING';
    severity      := CASE WHEN v_row.days_left <= 60 THEN 'HIGH' ELSE 'MEDIUM' END;
    client_code   := v_row.client_code;
    client_name   := v_row.client_name;
    object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
    description   := 'ULA expires in ' || v_row.days_left
                     || ' days. Certification must be completed before '
                     || v_row.ula_expiry;
    days_until    := v_row.days_left;
    action_needed := 'Run full deployment count and initiate ULA certification with Oracle';
    RETURN NEXT;
  END LOOP;

  -- Alert: unacknowledged HIGH severity changelog entries older than 7 days
  -- + SE2 violations + unrecognised CPUs (per-client schema loop)
  FOR v_client IN
    SELECT c.client_code, c.client_name, c.schema_name
    FROM   sam_admin.clients c WHERE c.is_active = TRUE
  LOOP

    -- Stale HIGH changelog entries
    BEGIN
      v_sql := format(
        $q$SELECT hostname, change_category, object_name, detected_at,
                  EXTRACT(EPOCH FROM (NOW() - detected_at)) / 86400 AS days_old
           FROM %I.discovery_changelog
           WHERE severity = 'HIGH' AND NOT acknowledged
             AND detected_at < NOW() - INTERVAL '7 days'$q$,
        v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'STALE_HIGH_CHANGE';
        severity      := 'HIGH';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.hostname || ': ' || v_row.object_name;
        description   := 'Unacknowledged HIGH severity change ('
                         || v_row.change_category || ') detected '
                         || ROUND(v_row.days_old) || ' days ago';
        days_until    := NULL;
        action_needed := 'Acknowledge in discovery_changelog; update server_csi_map if licence impact is confirmed';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- SE2 socket limit violations (max 2 sockets per server)
    BEGIN
      v_sql := format(
        $q$SELECT s.hostname, i.oracle_sid, p.cpu_sockets
           FROM   %I.oracle_servers s
           JOIN   %I.oracle_instances i ON i.server_id = s.server_id AND i.is_active
           JOIN   LATERAL (
             SELECT cpu_sockets FROM %I.oracle_processors
             WHERE  server_id = s.server_id
             ORDER  BY recorded_at DESC LIMIT 1
           ) p ON TRUE
           WHERE  s.is_active
             AND  (i.edition ILIKE '%%Standard Edition 2%%'
                   OR  i.edition = 'SE2')
             AND  p.cpu_sockets > 2$q$,
        v_client.schema_name, v_client.schema_name, v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'SE2_SOCKET_VIOLATION';
        severity      := 'HIGH';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.hostname || ' / ' || v_row.oracle_sid;
        description   := 'SE2 permits max 2 CPU sockets but server has '
                         || v_row.cpu_sockets || ' sockets';
        days_until    := NULL;
        action_needed := 'Upgrade to EE licence, reduce socket count, or move instance to a compliant server';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- SE2 RAC cluster size violations (max 2 nodes)
    BEGIN
      v_sql := format(
        $q$SELECT i.oracle_sid, COUNT(DISTINCT n.node_name) AS node_count
           FROM   %I.oracle_instances   i
           JOIN   %I.oracle_rac_nodes   n ON n.instance_id = i.instance_id
           WHERE  i.is_active
             AND  (i.edition ILIKE '%%Standard Edition 2%%' OR i.edition = 'SE2')
           GROUP  BY i.oracle_sid
           HAVING COUNT(DISTINCT n.node_name) > 2$q$,
        v_client.schema_name, v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'SE2_RAC_SIZE_VIOLATION';
        severity      := 'HIGH';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.oracle_sid;
        description   := 'SE2 RAC cluster has ' || v_row.node_count
                         || ' nodes — Oracle permits max 2 nodes in an SE2 RAC cluster';
        days_until    := NULL;
        action_needed := 'Remove nodes to reduce to ≤2, or upgrade all nodes to EE licences';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- Unrecognised CPU models (no matching entry in core_factor_table)
    BEGIN
      v_sql := format(
        $q$SELECT DISTINCT s.hostname, p.cpu_model
           FROM   %I.oracle_servers s
           JOIN   LATERAL (
             SELECT cpu_model FROM %I.oracle_processors
             WHERE  server_id = s.server_id
             ORDER  BY recorded_at DESC LIMIT 1
           ) p ON TRUE
           WHERE  s.is_active
             AND  p.cpu_model IS NOT NULL
             AND  shared.cpu_core_factor_lookup(p.cpu_model) IS NULL$q$,
        v_client.schema_name, v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'UNRECOGNISED_CPU';
        severity      := 'MEDIUM';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.hostname;
        description   := 'CPU model "' || v_row.cpu_model
                         || '" does not match any entry in the Oracle Processor Core Factor Table';
        days_until    := NULL;
        action_needed := 'Verify correct core factor at oracle.com/assets/processor-core-factor-table-070634.pdf and add to shared.core_factor_table';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

  END LOOP;

  -- Alert: licences with no policy or no client assignment
  FOR v_row IN
    SELECT csi_number, contract_name, allocation_status, product_families
    FROM   shared.unassigned_licences
  LOOP
    alert_type    := 'UNASSIGNED_LICENCE';
    severity      := 'MEDIUM';
    client_code   := NULL;
    client_name   := NULL;
    object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
    description   := v_row.allocation_status || ': '
                     || COALESCE(v_row.product_families, 'unknown product');
    days_until    := NULL;
    action_needed := CASE v_row.allocation_status
      WHEN 'NEEDS POLICY'     THEN 'Set sharing_policy via shared.set_csi_owner() or shared.assign_csi_to_client()'
      WHEN 'NEEDS ASSIGNMENT' THEN 'Assign this CSI to a client via shared.assign_csi_to_client()'
      ELSE 'Review and assign'
    END;
    RETURN NEXT;
  END LOOP;

  -- Alert: VMware clusters with Oracle workloads
  FOR v_row IN
    SELECT cluster_name, vcenter_host, client_code,
           host_count, total_sockets, total_physical_cores,
           oracle_db_vm_count, oracle_wls_vm_count
    FROM   sam_admin.vmware_licence_exposure
    WHERE  has_oracle_workloads = TRUE
  LOOP
    alert_type    := 'VMWARE_CLUSTER_EXPOSURE';
    severity      := 'HIGH';
    client_code   := v_row.client_code;
    client_name   := NULL;
    object_name   := v_row.cluster_name || ' @ ' || v_row.vcenter_host;
    description   := 'VMware cluster has ' || v_row.oracle_db_vm_count
                     || ' Oracle DB VM(s) and ' || v_row.oracle_wls_vm_count
                     || ' WLS VM(s) across ' || v_row.host_count || ' hosts ('
                     || v_row.total_sockets || ' sockets / '
                     || v_row.total_physical_cores || ' cores total). '
                     || 'Oracle requires the entire cluster to be licensed.';
    days_until    := NULL;
    action_needed := 'Verify licences cover all ' || v_row.total_physical_cores
                     || ' physical cores in this vSphere cluster, or implement Oracle-approved hard partitioning';
    RETURN NEXT;
  END LOOP;

END;
$$;

-- Refresh the convenience view (needed because the function was replaced)
CREATE OR REPLACE VIEW shared.compliance_alerts AS
SELECT * FROM shared.get_compliance_alerts();

-- ---------------------------------------------------------------------------
-- Client contacts — up to N named contacts per client (name, email, phone).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.client_contacts (
  contact_id   SERIAL PRIMARY KEY,
  client_id    INTEGER NOT NULL REFERENCES sam_admin.clients (client_id) ON DELETE CASCADE,
  full_name    TEXT NOT NULL DEFAULT '',
  email        TEXT NOT NULL DEFAULT '',
  phone        TEXT NOT NULL DEFAULT '',
  sort_order   INTEGER NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_client_contacts_client
  ON shared.client_contacts (client_id, sort_order);

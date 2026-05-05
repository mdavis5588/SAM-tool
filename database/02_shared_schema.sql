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

-- sharing_policy controls whether a CSI can be assigned to multiple clients:
--   client_locked : legally tied to one specific client — no sharing allowed.
--                   The owning_client_id column must be populated.
--   shareable     : can be assigned to multiple clients (e.g. group ULA).
--                   Quantity can be split via allocated_quantity in the map.
--   unassigned    : purchased but not yet associated with any client.
--                   Appears prominently in the unassigned licences view.
CREATE TYPE shared.sharing_policy AS ENUM
  ('client_locked', 'shareable', 'unassigned');

-- ---------------------------------------------------------------------------
-- LICENSE ENTITLEMENTS
-- What you (or your clients) actually own from Oracle.
-- sharing_policy and owning_client_id control who can use each CSI.
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

  -- Sharing controls
  sharing_policy    shared.sharing_policy NOT NULL DEFAULT 'unassigned',
  owning_client_id  INTEGER REFERENCES sam_admin.clients (client_id),
                    -- Must be set when sharing_policy = 'client_locked'.
                    -- Optional for 'shareable' (documents the purchasing entity).
                    -- NULL for 'unassigned'.

  notes             TEXT,
  status            shared.license_status NOT NULL DEFAULT 'active',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_quantity       CHECK (quantity >= 0),
  CONSTRAINT chk_csi_fmt        CHECK (csi_number IS NULL OR csi_number ~ '^\d+$'),
  CONSTRAINT chk_locked_owner   CHECK (
    sharing_policy <> 'client_locked' OR owning_client_id IS NOT NULL
  )
  -- "If client_locked, owning_client_id must be set."
);

CREATE INDEX idx_ent_csi        ON shared.license_entitlements (csi_number);
CREATE INDEX idx_ent_product    ON shared.license_entitlements (product_name);
CREATE INDEX idx_ent_family     ON shared.license_entitlements (product_family);
CREATE INDEX idx_ent_status     ON shared.license_entitlements (status);
CREATE INDEX idx_ent_policy     ON shared.license_entitlements (sharing_policy);
CREATE INDEX idx_ent_owner      ON shared.license_entitlements (owning_client_id);

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
-- Many-to-many: one CSI can cover multiple clients (shareable),
-- or exactly one client (client_locked).
-- A trigger below enforces that client_locked CSIs have at most one mapping.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.entitlement_client_map (
  map_id             SERIAL PRIMARY KEY,
  entitlement_id     INTEGER NOT NULL
                       REFERENCES shared.license_entitlements (entitlement_id) ON DELETE CASCADE,
  client_id          INTEGER NOT NULL
                       REFERENCES sam_admin.clients (client_id) ON DELETE CASCADE,
  allocated_quantity NUMERIC(10,2),   -- NULL = full entitlement quantity available to this client
  allocation_notes   TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (entitlement_id, client_id)
);

CREATE INDEX idx_ecm_entitlement ON shared.entitlement_client_map (entitlement_id);
CREATE INDEX idx_ecm_client      ON shared.entitlement_client_map (client_id);

-- ---------------------------------------------------------------------------
-- TRIGGER: enforce sharing policy on insert/update of the map
-- Prevents a client_locked CSI from being assigned to more than one client,
-- and prevents assigning a client_locked CSI to a client that is not the owner.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION shared.enforce_sharing_policy()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_policy   shared.sharing_policy;
  v_owner    INTEGER;
  v_existing INTEGER;
BEGIN
  SELECT sharing_policy, owning_client_id
  INTO   v_policy, v_owner
  FROM   shared.license_entitlements
  WHERE  entitlement_id = NEW.entitlement_id;

  IF v_policy = 'unassigned' THEN
    RAISE EXCEPTION
      'Entitlement % has sharing_policy = unassigned. '
      'Set sharing_policy to client_locked or shareable before assigning to a client.',
      NEW.entitlement_id;
  END IF;

  IF v_policy = 'client_locked' THEN
    -- Must be assigned to the owning client only
    IF NEW.client_id <> v_owner THEN
      RAISE EXCEPTION
        'Entitlement % is client_locked to client_id %. '
        'It cannot be assigned to client_id %.',
        NEW.entitlement_id, v_owner, NEW.client_id;
    END IF;

    -- Must not already have a mapping (i.e. enforce single-client)
    SELECT COUNT(*) INTO v_existing
    FROM   shared.entitlement_client_map
    WHERE  entitlement_id = NEW.entitlement_id
      AND  map_id <> COALESCE(NEW.map_id, -1);  -- exclude self on UPDATE

    IF v_existing > 0 THEN
      RAISE EXCEPTION
        'Entitlement % is client_locked and already has a client assignment. '
        'A client_locked CSI can only be assigned to one client.',
        NEW.entitlement_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_sharing
  BEFORE INSERT OR UPDATE ON shared.entitlement_client_map
  FOR EACH ROW EXECUTE FUNCTION shared.enforce_sharing_policy();

-- ---------------------------------------------------------------------------
-- HELPER: assign_entitlement_to_client()
-- Convenience function that handles policy checks, sets sharing_policy,
-- and inserts/updates the map row in one call.
--
-- Usage:
--   -- Lock a CSI to one client:
--   SELECT shared.assign_entitlement_to_client(1, 'acme', 'client_locked');
--
--   -- Share a CSI across clients (call once per client):
--   SELECT shared.assign_entitlement_to_client(2, 'acme',   'shareable', 60);
--   SELECT shared.assign_entitlement_to_client(2, 'globex', 'shareable', 40);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION shared.assign_entitlement_to_client(
  p_entitlement_id   INTEGER,
  p_client_code      TEXT,
  p_policy           shared.sharing_policy,   -- 'client_locked' or 'shareable'
  p_quantity         NUMERIC DEFAULT NULL,
  p_notes            TEXT    DEFAULT NULL
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_client_id  INTEGER;
  v_current_policy shared.sharing_policy;
BEGIN
  -- Resolve client
  SELECT client_id INTO v_client_id
  FROM   sam_admin.clients
  WHERE  client_code = p_client_code AND is_active = TRUE;

  IF v_client_id IS NULL THEN
    RAISE EXCEPTION 'Client code % not found or inactive.', p_client_code;
  END IF;

  -- Check the entitlement exists
  SELECT sharing_policy INTO v_current_policy
  FROM   shared.license_entitlements
  WHERE  entitlement_id = p_entitlement_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entitlement % not found.', p_entitlement_id;
  END IF;

  -- If currently unassigned, set the policy and (for client_locked) the owner
  IF v_current_policy = 'unassigned' THEN
    UPDATE shared.license_entitlements
    SET    sharing_policy   = p_policy,
           owning_client_id = CASE WHEN p_policy = 'client_locked' THEN v_client_id ELSE owning_client_id END
    WHERE  entitlement_id   = p_entitlement_id;

  ELSIF v_current_policy <> p_policy THEN
    RAISE EXCEPTION
      'Entitlement % already has sharing_policy = %. Cannot change to % via this function. '
      'Update license_entitlements directly if the policy needs to change.',
      p_entitlement_id, v_current_policy, p_policy;
  END IF;

  -- Insert or update the map row (trigger will re-validate policy)
  INSERT INTO shared.entitlement_client_map
    (entitlement_id, client_id, allocated_quantity, allocation_notes)
  VALUES
    (p_entitlement_id, v_client_id, p_quantity, p_notes)
  ON CONFLICT (entitlement_id, client_id) DO UPDATE
    SET allocated_quantity = EXCLUDED.allocated_quantity,
        allocation_notes   = EXCLUDED.allocation_notes;

  RETURN format('Entitlement %s assigned to client %s (policy: %s).',
                p_entitlement_id, p_client_code, p_policy);
END;
$$;

-- ---------------------------------------------------------------------------
-- HELPER: set_entitlement_owner()
-- Sets or changes the owning client on an existing entitlement using
-- client_code rather than a raw integer ID.
-- Works for both client_locked (required) and shareable (optional/informational).
-- Pass p_client_code => NULL to clear the owner on a shareable entitlement.
--
-- Usage:
--   -- Declare that CSI 3 is legally owned by Acme:
--   SELECT shared.set_entitlement_owner(3, 'acme');
--
--   -- Lock it at the same time:
--   SELECT shared.set_entitlement_owner(3, 'acme', lock => TRUE);
--
--   -- Clear the owner from a shareable entitlement:
--   SELECT shared.set_entitlement_owner(2, NULL);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION shared.set_entitlement_owner(
  p_entitlement_id  INTEGER,
  p_client_code     TEXT,                    -- client_code from sam_admin.clients, or NULL to clear
  p_lock            BOOLEAN DEFAULT FALSE    -- if TRUE, also sets sharing_policy = 'client_locked'
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_client_id      INTEGER;
  v_current_policy shared.sharing_policy;
  v_current_owner  INTEGER;
BEGIN
  -- Resolve client code → id (unless clearing)
  IF p_client_code IS NOT NULL THEN
    SELECT client_id INTO v_client_id
    FROM   sam_admin.clients
    WHERE  client_code = p_client_code AND is_active = TRUE;

    IF v_client_id IS NULL THEN
      RAISE EXCEPTION 'Client code "%" not found or inactive.', p_client_code;
    END IF;
  END IF;

  -- Read current state
  SELECT sharing_policy, owning_client_id
  INTO   v_current_policy, v_current_owner
  FROM   shared.license_entitlements
  WHERE  entitlement_id = p_entitlement_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entitlement % not found.', p_entitlement_id;
  END IF;

  -- Prevent clearing the owner on a client_locked entitlement
  IF p_client_code IS NULL AND v_current_policy = 'client_locked' THEN
    RAISE EXCEPTION
      'Cannot clear owning_client on entitlement % because sharing_policy = client_locked. '
      'Change the policy to shareable first, or supply a new client_code.',
      p_entitlement_id;
  END IF;

  -- Apply the update
  UPDATE shared.license_entitlements
  SET
    owning_client_id = v_client_id,   -- NULL if p_client_code is NULL
    sharing_policy   = CASE
                         WHEN p_lock THEN 'client_locked'::shared.sharing_policy
                         ELSE sharing_policy   -- leave unchanged unless p_lock = TRUE
                       END
  WHERE entitlement_id = p_entitlement_id;

  RETURN format(
    'Entitlement %s: owner set to %s%s.',
    p_entitlement_id,
    COALESCE(p_client_code, 'NULL (cleared)'),
    CASE WHEN p_lock THEN ', policy set to client_locked' ELSE '' END
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- HELPER: add_entitlement()
-- Creates a new entitlement record using client_code strings throughout —
-- no integer IDs needed anywhere.
-- Returns the new entitlement_id.
--
-- Usage:
--   -- Add a client-locked CSI for Acme (auto-assigns it too):
--   SELECT shared.add_entitlement(
--     p_csi           => '12345678',
--     p_product_name  => 'Oracle Database Enterprise Edition',
--     p_product_family => 'oracle_database',
--     p_metric        => 'processor',
--     p_quantity      => 50,
--     p_locked_to     => 'acme',
--     p_support_expiry => '2027-01-01'
--   );
--
--   -- Add a shareable CSI (no owner yet):
--   SELECT shared.add_entitlement(
--     p_csi           => '99999999',
--     p_product_name  => 'Oracle WebLogic Server Enterprise Edition',
--     p_product_family => 'oracle_weblogic',
--     p_metric        => 'processor',
--     p_quantity      => 100,
--     p_policy        => 'shareable',
--     p_support_expiry => '2027-06-01'
--   );
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION shared.add_entitlement(
  p_product_name    TEXT,
  p_quantity        NUMERIC,
  p_product_family  shared.product_family   DEFAULT 'oracle_database',
  p_metric          shared.license_metric   DEFAULT 'processor',
  p_csi             TEXT                    DEFAULT NULL,
  p_purchase_date   DATE                    DEFAULT NULL,
  p_support_start   DATE                    DEFAULT NULL,
  p_support_expiry  DATE                    DEFAULT NULL,
  p_ula_expiry      DATE                    DEFAULT NULL,
  p_vendor_ref      TEXT                    DEFAULT NULL,
  p_is_ula          BOOLEAN                 DEFAULT FALSE,
  p_notes           TEXT                    DEFAULT NULL,
  -- Sharing: supply p_locked_to to create a client_locked entitlement,
  -- or p_policy = 'shareable' for a shared pool.
  -- Omit both to leave as 'unassigned'.
  p_locked_to       TEXT                    DEFAULT NULL,  -- client_code for client_locked
  p_policy          shared.sharing_policy   DEFAULT 'unassigned'
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
  v_client_id   INTEGER;
  v_policy      shared.sharing_policy;
  v_new_id      INTEGER;
BEGIN
  -- Resolve locked_to client if supplied
  IF p_locked_to IS NOT NULL THEN
    SELECT client_id INTO v_client_id
    FROM   sam_admin.clients
    WHERE  client_code = p_locked_to AND is_active = TRUE;

    IF v_client_id IS NULL THEN
      RAISE EXCEPTION 'p_locked_to: client code "%" not found or inactive.', p_locked_to;
    END IF;

    -- p_locked_to implies client_locked policy regardless of p_policy
    v_policy := 'client_locked';

  ELSE
    v_policy := p_policy;
  END IF;

  -- Validate: client_locked requires a client
  IF v_policy = 'client_locked' AND v_client_id IS NULL THEN
    RAISE EXCEPTION
      'sharing_policy = client_locked requires p_locked_to to be set.';
  END IF;

  INSERT INTO shared.license_entitlements (
    csi_number, product_name, product_family, license_metric,
    quantity, purchase_date, support_start, support_expiry,
    ula_expiry, vendor_reference, is_ula, notes,
    sharing_policy, owning_client_id
  ) VALUES (
    p_csi, p_product_name, p_product_family, p_metric,
    p_quantity, p_purchase_date, p_support_start, p_support_expiry,
    p_ula_expiry, p_vendor_ref, p_is_ula, p_notes,
    v_policy, v_client_id
  )
  RETURNING entitlement_id INTO v_new_id;

  -- If client_locked, auto-assign to the owning client
  IF v_policy = 'client_locked' THEN
    INSERT INTO shared.entitlement_client_map (entitlement_id, client_id)
    VALUES (v_new_id, v_client_id);
  END IF;

  RETURN v_new_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- HELPER VIEW: entitlements_by_client
-- Used by client schema license_position view — filters to assigned CSIs only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.entitlements_by_client AS
SELECT
  e.entitlement_id,
  e.csi_number,
  e.product_name,
  e.product_family,
  e.license_metric,
  e.quantity                                     AS total_quantity,
  COALESCE(m.allocated_quantity, e.quantity)     AS client_quantity,
  e.sharing_policy,
  e.owning_client_id,
  e.support_expiry,
  e.ula_expiry,
  e.is_ula,
  e.status,
  c.client_id,
  c.client_code,
  c.client_name,
  c.schema_name
FROM   shared.license_entitlements     e
JOIN   shared.entitlement_client_map   m ON m.entitlement_id = e.entitlement_id
JOIN   sam_admin.clients               c ON c.client_id = m.client_id
WHERE  c.is_active = TRUE;

-- ---------------------------------------------------------------------------
-- UNASSIGNED LICENCES VIEW
-- Shows every entitlement that has no client assignment OR has leftover
-- unallocated quantity, with sharing_policy clearly surfaced.
-- This is the primary "action required" view for licence administrators.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.unassigned_licences AS
WITH allocation_summary AS (
  SELECT
    e.entitlement_id,
    COUNT(m.client_id)                              AS assigned_client_count,
    COALESCE(SUM(m.allocated_quantity), 0)          AS total_explicitly_allocated,
    -- If any mapping has NULL allocated_quantity it means "full quantity" given to that client
    BOOL_OR(m.allocated_quantity IS NULL)           AS any_full_allocation
  FROM   shared.license_entitlements   e
  LEFT   JOIN shared.entitlement_client_map m ON m.entitlement_id = e.entitlement_id
  GROUP  BY e.entitlement_id
)
SELECT
  e.entitlement_id,
  e.csi_number,
  e.product_name,
  e.product_family::TEXT,
  e.license_metric::TEXT,
  e.quantity                                        AS total_quantity,
  e.sharing_policy::TEXT,
  e.status::TEXT,
  e.support_expiry,
  e.ula_expiry,
  e.is_ula,
  e.purchase_date,
  e.vendor_reference,
  e.notes,

  -- Owner info (for client_locked CSIs)
  oc.client_code                                    AS locked_to_client,
  oc.client_name                                    AS locked_to_client_name,

  -- Assignment state
  a.assigned_client_count,

  -- Unallocated quantity:
  --   If any mapping is "full allocation" (NULL quantity), none is truly unallocated.
  --   Otherwise it is total_quantity minus what has been explicitly split out.
  CASE
    WHEN a.any_full_allocation THEN 0
    ELSE GREATEST(e.quantity - a.total_explicitly_allocated, 0)
  END                                               AS unallocated_quantity,

  -- Actionable status — what does this entitlement need?
  CASE
    WHEN e.sharing_policy = 'unassigned'
      THEN 'NEEDS POLICY — set to client_locked or shareable, then assign'
    WHEN a.assigned_client_count = 0
      THEN 'NEEDS ASSIGNMENT — policy set but no client assigned yet'
    WHEN NOT a.any_full_allocation
      AND GREATEST(e.quantity - a.total_explicitly_allocated, 0) > 0
      THEN 'PARTIALLY ALLOCATED — ' ||
           GREATEST(e.quantity - a.total_explicitly_allocated, 0)::TEXT ||
           ' licences unallocated'
    ELSE 'FULLY ALLOCATED'
  END                                               AS allocation_status,

  -- Can this CSI still accept more client assignments?
  CASE
    WHEN e.sharing_policy = 'client_locked'  THEN FALSE
    WHEN e.sharing_policy = 'unassigned'     THEN FALSE
    ELSE TRUE
  END                                               AS can_share,

  -- Expiry health
  CASE
    WHEN e.support_expiry IS NULL                                       THEN 'no_expiry_set'
    WHEN e.support_expiry < CURRENT_DATE                                THEN 'expired'
    WHEN e.support_expiry < CURRENT_DATE + INTERVAL '90 days'          THEN 'expiring_soon'
    ELSE 'current'
  END                                               AS support_status,

  CASE
    WHEN e.ula_expiry IS NULL                                           THEN NULL
    WHEN e.ula_expiry < CURRENT_DATE                                    THEN 'ula_expired'
    WHEN e.ula_expiry < CURRENT_DATE + INTERVAL '180 days'             THEN 'ula_expiring'
    ELSE 'ula_current'
  END                                               AS ula_status

FROM   shared.license_entitlements   e
LEFT   JOIN allocation_summary        a  ON a.entitlement_id = e.entitlement_id
LEFT   JOIN sam_admin.clients         oc ON oc.client_id = e.owning_client_id
WHERE
  -- Include everything that is NOT fully allocated, plus unassigned policy
  e.sharing_policy = 'unassigned'
  OR a.assigned_client_count = 0
  OR (
    NOT a.any_full_allocation
    AND GREATEST(e.quantity - a.total_explicitly_allocated, 0) > 0
  )
ORDER BY
  CASE e.sharing_policy
    WHEN 'unassigned' THEN 1
    ELSE 2
  END,
  a.assigned_client_count,
  e.product_family,
  e.product_name;

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
-- Full picture of every entitlement: allocation, sharing policy, and expiry.
-- Intended for the admin entitlement register report page.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared.entitlement_utilisation AS
WITH allocation_summary AS (
  SELECT
    entitlement_id,
    COUNT(client_id)                         AS assigned_client_count,
    STRING_AGG(c.client_code, ', ' ORDER BY c.client_code) AS assigned_clients,
    COALESCE(SUM(allocated_quantity), 0)     AS total_explicitly_allocated,
    BOOL_OR(allocated_quantity IS NULL)      AS any_full_allocation
  FROM   shared.entitlement_client_map m
  JOIN   sam_admin.clients c ON c.client_id = m.client_id
  GROUP  BY entitlement_id
)
SELECT
  e.entitlement_id,
  e.csi_number,
  e.product_name,
  e.product_family,
  e.license_metric,
  e.quantity                                       AS total_quantity,
  e.sharing_policy,
  e.status,
  e.support_expiry,
  e.ula_expiry,
  e.is_ula,
  e.purchase_date,
  e.vendor_reference,

  -- Owning client (populated for client_locked, optional for shareable)
  oc.client_code                                   AS owning_client,
  oc.client_name                                   AS owning_client_name,

  -- Assignment summary
  COALESCE(a.assigned_client_count, 0)             AS assigned_client_count,
  COALESCE(a.assigned_clients, '—')                AS assigned_clients,

  -- Unallocated quantity
  CASE
    WHEN a.any_full_allocation THEN 0
    ELSE GREATEST(e.quantity - COALESCE(a.total_explicitly_allocated, 0), 0)
  END                                              AS unallocated_quantity,

  -- Can accept more assignments?
  CASE
    WHEN e.sharing_policy = 'shareable' THEN TRUE
    ELSE FALSE
  END                                              AS can_share,

  -- Allocation status (matches unassigned_licences view)
  CASE
    WHEN e.sharing_policy = 'unassigned'
      THEN 'NEEDS POLICY'
    WHEN COALESCE(a.assigned_client_count, 0) = 0
      THEN 'NEEDS ASSIGNMENT'
    WHEN NOT COALESCE(a.any_full_allocation, FALSE)
      AND GREATEST(e.quantity - COALESCE(a.total_explicitly_allocated, 0), 0) > 0
      THEN 'PARTIALLY ALLOCATED'
    ELSE 'FULLY ALLOCATED'
  END                                              AS allocation_status,

  CASE
    WHEN e.support_expiry IS NULL                                  THEN 'no_expiry_set'
    WHEN e.support_expiry < CURRENT_DATE                           THEN 'expired'
    WHEN e.support_expiry < CURRENT_DATE + INTERVAL '90 days'     THEN 'expiring_soon'
    ELSE 'current'
  END                                              AS support_status,

  CASE
    WHEN e.ula_expiry IS NULL                                      THEN NULL
    WHEN e.ula_expiry < CURRENT_DATE                               THEN 'ula_expired'
    WHEN e.ula_expiry < CURRENT_DATE + INTERVAL '180 days'        THEN 'ula_expiring'
    ELSE 'ula_current'
  END                                              AS ula_status

FROM   shared.license_entitlements   e
LEFT   JOIN allocation_summary        a  ON a.entitlement_id = e.entitlement_id
LEFT   JOIN sam_admin.clients         oc ON oc.client_id = e.owning_client_id
ORDER  BY e.product_family, e.product_name;

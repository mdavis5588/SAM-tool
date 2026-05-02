-- =============================================================================
-- Oracle SAM - PostgreSQL Schema
-- Database: oracle_sam
-- Schema:   oracle
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS oracle;
SET search_path = oracle, public;

-- ---------------------------------------------------------------------------
-- ENUM TYPES
-- ---------------------------------------------------------------------------
CREATE TYPE oracle.environment_type AS ENUM
  ('production', 'non_production', 'development', 'test', 'dr', 'unknown');

CREATE TYPE oracle.virt_type AS ENUM
  ('physical', 'vmware', 'hyperv', 'kvm', 'xen', 'lpar', 'zone', 'container', 'unknown');

CREATE TYPE oracle.license_metric AS ENUM
  ('named_user_plus', 'processor', 'ula', 'cloud_license');

CREATE TYPE oracle.license_status AS ENUM
  ('active', 'expired', 'pending', 'terminated');

-- ---------------------------------------------------------------------------
-- 1. ORACLE SERVERS
--    One row per physical / virtual host. Updated on each discovery run.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS oracle.oracle_servers (
  server_id           SERIAL PRIMARY KEY,
  hostname            TEXT NOT NULL UNIQUE,
  fqdn                TEXT,
  ip_address          INET,
  os_family           TEXT,
  os_distribution     TEXT,
  os_version          TEXT,
  environment         oracle.environment_type NOT NULL DEFAULT 'unknown',
  criticality         TEXT,
  total_ram_mb        INTEGER,
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  first_seen          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_discovery_run  TEXT,
  notes               TEXT,
  CONSTRAINT chk_hostname CHECK (hostname <> '')
);

CREATE INDEX idx_servers_env      ON oracle.oracle_servers (environment);
CREATE INDEX idx_servers_active   ON oracle.oracle_servers (is_active);

-- ---------------------------------------------------------------------------
-- 2. PROCESSOR DATA
--    Separate table so history can be tracked across runs.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS oracle.oracle_processors (
  proc_id             SERIAL PRIMARY KEY,
  server_id           INTEGER NOT NULL REFERENCES oracle.oracle_servers (server_id) ON DELETE CASCADE,
  cpu_model           TEXT NOT NULL,
  cpu_architecture    TEXT,
  cpu_sockets         INTEGER NOT NULL DEFAULT 1,
  cores_per_socket    INTEGER NOT NULL DEFAULT 1,
  threads_per_core    INTEGER NOT NULL DEFAULT 1,
  total_physical_cores  INTEGER GENERATED ALWAYS AS (cpu_sockets * cores_per_socket) STORED,
  virt_type           oracle.virt_type NOT NULL DEFAULT 'unknown',
  virt_role           TEXT,
  is_vmware           BOOLEAN NOT NULL DEFAULT FALSE,
  vcpu_count          INTEGER,           -- populated for VMs, NULL for physical
  recorded_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  discovery_run_id    TEXT,
  CONSTRAINT chk_sockets    CHECK (cpu_sockets > 0),
  CONSTRAINT chk_cores      CHECK (cores_per_socket > 0)
);

CREATE INDEX idx_proc_server  ON oracle.oracle_processors (server_id);
CREATE INDEX idx_proc_run     ON oracle.oracle_processors (discovery_run_id);

-- ---------------------------------------------------------------------------
-- 3. ORACLE CORE FACTOR TABLE
--    Source: Oracle Processor Core Factor Table (update from Oracle's website).
--    Core factor determines how many licences a physical core counts as.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS oracle.core_factor_table (
  core_factor_id    SERIAL PRIMARY KEY,
  processor_pattern TEXT NOT NULL,     -- ILIKE pattern, e.g. '%Intel%Xeon%'
  core_factor       NUMERIC(4,2) NOT NULL,  -- e.g. 0.5 for Intel Xeon
  notes             TEXT,
  effective_date    DATE NOT NULL DEFAULT CURRENT_DATE,
  CONSTRAINT chk_factor CHECK (core_factor > 0 AND core_factor <= 1)
);

-- Seed the table with Oracle's published core factors (as at 2024).
-- Always verify against: https://www.oracle.com/us/corporate/contracts/processor-core-factor-table-070634.pdf
INSERT INTO oracle.core_factor_table (processor_pattern, core_factor, notes) VALUES
  ('%Intel%Xeon%',           0.5,  'Intel Xeon multi-core (all models)'),
  ('%Intel%Core%',           0.5,  'Intel Core i-series'),
  ('%Intel%Pentium%',        0.5,  'Intel Pentium'),
  ('%Intel%Celeron%',        0.5,  'Intel Celeron'),
  ('%AMD%EPYC%',             0.5,  'AMD EPYC'),
  ('%AMD%Opteron%',          0.5,  'AMD Opteron'),
  ('%AMD%Ryzen%',            0.5,  'AMD Ryzen'),
  ('%ARM%',                  0.5,  'ARM-based processors'),
  ('%Apple%M%',              0.5,  'Apple Silicon M-series'),
  ('%IBM%POWER9%',           1.0,  'IBM POWER9'),
  ('%IBM%POWER10%',          1.0,  'IBM POWER10'),
  ('%SPARC%T%',              0.25, 'Oracle SPARC T-series (UltraSPARC T)'),
  ('%SPARC%M%',              0.5,  'Oracle SPARC M-series'),
  ('Unknown',                1.0,  'Default factor for unrecognised processors');

-- ---------------------------------------------------------------------------
-- 4. ORACLE INSTANCES
--    One row per Oracle database SID on a server.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS oracle.oracle_instances (
  instance_id       SERIAL PRIMARY KEY,
  server_id         INTEGER NOT NULL REFERENCES oracle.oracle_servers (server_id) ON DELETE CASCADE,
  oracle_sid        TEXT NOT NULL,
  db_name           TEXT,
  oracle_home       TEXT,
  edition           TEXT,        -- Enterprise Edition, Standard Edition 2, etc.
  version           TEXT,        -- e.g. 19.0.0.0.0
  platform_name     TEXT,
  created_date      DATE,
  autostart         BOOLEAN,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  first_seen        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  discovery_run_id  TEXT,
  UNIQUE (server_id, oracle_sid)
);

CREATE INDEX idx_inst_server  ON oracle.oracle_instances (server_id);
CREATE INDEX idx_inst_edition ON oracle.oracle_instances (edition);

-- ---------------------------------------------------------------------------
-- 5. ORACLE INSTALLED OPTIONS
--    Options and packs can affect licence requirements (Diagnostic Pack, etc.)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS oracle.oracle_options (
  option_id         SERIAL PRIMARY KEY,
  instance_id       INTEGER NOT NULL REFERENCES oracle.oracle_instances (instance_id) ON DELETE CASCADE,
  option_name       TEXT NOT NULL,
  option_version    TEXT,
  status            TEXT,
  discovery_run_id  TEXT,
  recorded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_opt_instance ON oracle.oracle_options (instance_id);

-- ---------------------------------------------------------------------------
-- 6. LICENCE ENTITLEMENTS
--    What you actually own — entered manually or via CSV import.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS oracle.license_entitlements (
  entitlement_id    SERIAL PRIMARY KEY,
  csi_number        TEXT,              -- Oracle Customer Support Identifier
  product_name      TEXT NOT NULL,     -- e.g. 'Oracle Database Enterprise Edition'
  license_metric    oracle.license_metric NOT NULL DEFAULT 'processor',
  quantity          NUMERIC(10,2) NOT NULL,
  purchase_date     DATE,
  support_expiry    DATE,
  ula_expiry        DATE,              -- populated for Unlimited Licence Agreements
  vendor_reference  TEXT,
  notes             TEXT,
  status            oracle.license_status NOT NULL DEFAULT 'active',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_quantity CHECK (quantity >= 0)
);

CREATE INDEX idx_ent_product ON oracle.license_entitlements (product_name);
CREATE INDEX idx_ent_status  ON oracle.license_entitlements (status);

-- ---------------------------------------------------------------------------
-- 7. DISCOVERY RUNS
--    Audit log of every Ansible execution.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS oracle.discovery_runs (
  run_id            TEXT PRIMARY KEY,
  started_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at      TIMESTAMPTZ,
  hosts_targeted    INTEGER,
  hosts_succeeded   INTEGER,
  hosts_failed      INTEGER,
  triggered_by      TEXT,
  ansible_version   TEXT,
  notes             TEXT
);

-- ---------------------------------------------------------------------------
-- 8. UPSERT FUNCTION
--    Called by Ansible to load a single host's discovery payload.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION oracle.upsert_server_discovery(p_payload JSONB)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_server_id  INTEGER;
  v_instance   JSONB;
  v_option     JSONB;
  v_cf         NUMERIC(4,2);
BEGIN
  -- Upsert server record
  INSERT INTO oracle.oracle_servers
    (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
     environment, criticality, total_ram_mb, last_seen, last_discovery_run)
  VALUES (
    p_payload->>'hostname',
    p_payload->>'fqdn',
    (p_payload->>'ip_address')::INET,
    p_payload->>'os_family',
    p_payload->>'os_distribution',
    p_payload->>'os_version',
    (p_payload->>'environment')::oracle.environment_type,
    p_payload->>'criticality',
    (p_payload->>'total_ram_mb')::INTEGER,
    NOW(),
    p_payload->>'run_id'
  )
  ON CONFLICT (hostname) DO UPDATE SET
    fqdn               = EXCLUDED.fqdn,
    ip_address         = EXCLUDED.ip_address,
    os_family          = EXCLUDED.os_family,
    os_distribution    = EXCLUDED.os_distribution,
    os_version         = EXCLUDED.os_version,
    environment        = EXCLUDED.environment,
    criticality        = EXCLUDED.criticality,
    total_ram_mb       = EXCLUDED.total_ram_mb,
    last_seen          = NOW(),
    last_discovery_run = EXCLUDED.last_discovery_run
  RETURNING server_id INTO v_server_id;

  -- Insert processor snapshot
  INSERT INTO oracle.oracle_processors
    (server_id, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
     threads_per_core, virt_type, virt_role, is_vmware, vcpu_count,
     discovery_run_id)
  VALUES (
    v_server_id,
    p_payload->>'cpu_model',
    p_payload->>'cpu_architecture',
    (p_payload->>'cpu_sockets')::INTEGER,
    (p_payload->>'cpu_cores_per_socket')::INTEGER,
    (p_payload->>'cpu_threads_per_core')::INTEGER,
    (COALESCE(p_payload->>'virt_type', 'unknown'))::sam.virt_type,
    p_payload->>'virt_role',
    (p_payload->>'is_vmware')::BOOLEAN,
    NULL,
    p_payload->>'run_id'
  );

  -- Upsert oracle instances
  FOR v_instance IN SELECT * FROM jsonb_array_elements(p_payload->'instances')
  LOOP
    INSERT INTO oracle.oracle_instances
      (server_id, oracle_sid, db_name, edition, version, platform_name,
       last_seen, discovery_run_id)
    VALUES (
      v_server_id,
      v_instance->>'db_name',
      v_instance->>'db_name',
      v_instance->>'edition',
      v_instance->>'version',
      v_instance->>'platform_name',
      NOW(),
      p_payload->>'run_id'
    )
    ON CONFLICT (server_id, oracle_sid) DO UPDATE SET
      edition          = EXCLUDED.edition,
      version          = EXCLUDED.version,
      platform_name    = EXCLUDED.platform_name,
      last_seen        = NOW(),
      discovery_run_id = EXCLUDED.discovery_run_id;
  END LOOP;

END;
$$;

-- ---------------------------------------------------------------------------
-- 9. LICENSE POSITION VIEW
--    Core business view: calculated licence requirement vs entitlement.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW oracle.license_position AS
WITH latest_proc AS (
  -- Take the most recent processor snapshot per server
  SELECT DISTINCT ON (server_id)
         server_id,
         cpu_model,
         cpu_sockets,
         cores_per_socket,
         total_physical_cores,
         virt_type,
         is_vmware
  FROM   oracle.oracle_processors
  ORDER  BY server_id, recorded_at DESC
),
server_core_factor AS (
  -- Match CPU model to Oracle core factor
  SELECT
    lp.server_id,
    lp.cpu_model,
    lp.cpu_sockets,
    lp.cores_per_socket,
    lp.total_physical_cores,
    lp.virt_type,
    lp.is_vmware,
    COALESCE(
      (SELECT cf.core_factor
       FROM   oracle.core_factor_table cf
       WHERE  lp.cpu_model ILIKE cf.processor_pattern
         AND  cf.processor_pattern <> 'Unknown'
       ORDER  BY cf.effective_date DESC
       LIMIT  1),
      (SELECT cf.core_factor FROM oracle.core_factor_table cf WHERE cf.processor_pattern = 'Unknown' LIMIT 1),
      0.5   -- safe fallback
    ) AS core_factor
  FROM   latest_proc lp
),
licence_required AS (
  -- EE: cores × core_factor.  SE2: processor count (capped at 2).
  SELECT
    s.server_id,
    s.hostname,
    s.environment,
    i.edition,
    scf.cpu_sockets,
    scf.total_physical_cores,
    scf.cpu_model,
    scf.core_factor,
    scf.virt_type,
    scf.is_vmware,
    CASE
      WHEN i.edition ILIKE '%Enterprise%' THEN
        ROUND(scf.total_physical_cores * scf.core_factor, 2)
      WHEN i.edition ILIKE '%Standard Edition 2%' THEN
        LEAST(scf.cpu_sockets, 2)::NUMERIC
      WHEN i.edition ILIKE '%Standard Edition%' THEN
        scf.cpu_sockets::NUMERIC
      ELSE
        ROUND(scf.total_physical_cores * scf.core_factor, 2)
    END AS licences_required
  FROM   oracle.oracle_instances   i
  JOIN   oracle.oracle_servers     s   ON s.server_id = i.server_id
  JOIN   server_core_factor     scf ON scf.server_id = i.server_id
  WHERE  s.is_active = TRUE
    AND  i.is_active = TRUE
),
entitlement_total AS (
  SELECT product_name,
         SUM(quantity) AS total_licensed
  FROM   oracle.license_entitlements
  WHERE  status = 'active'
  GROUP  BY product_name
)
SELECT
  lr.server_id,
  lr.hostname,
  lr.environment,
  lr.edition,
  lr.cpu_sockets,
  lr.total_physical_cores,
  lr.cpu_model,
  lr.core_factor,
  lr.virt_type,
  lr.is_vmware,
  lr.licences_required,
  COALESCE(et.total_licensed, 0) AS total_licensed,
  COALESCE(et.total_licensed, 0) - SUM(lr.licences_required) OVER (PARTITION BY lr.edition)
    AS licence_surplus_deficit
FROM   licence_required lr
LEFT   JOIN entitlement_total et
  ON et.product_name ILIKE '%' || CASE WHEN lr.edition ILIKE '%Enterprise%' THEN 'Enterprise' ELSE 'Standard' END || '%'
ORDER  BY lr.environment, lr.hostname;

COMMENT ON VIEW oracle.license_position IS
  'Calculates Oracle processor licence requirements per server using the Oracle Core Factor Table '
  'and compares against active entitlements. EE uses cores × core_factor; SE2 caps at 2 sockets.';

-- ---------------------------------------------------------------------------
-- 10. HELPER: SERVER SUMMARY (for Power BI direct use)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW oracle.server_summary AS
SELECT
  s.server_id,
  s.hostname,
  s.fqdn,
  s.environment,
  s.os_distribution,
  s.os_version,
  s.is_active,
  s.last_seen,
  p.cpu_model,
  p.cpu_sockets,
  p.cores_per_socket,
  p.total_physical_cores,
  p.virt_type,
  p.is_vmware,
  COUNT(i.instance_id)                                    AS oracle_instance_count,
  STRING_AGG(DISTINCT i.edition, ', ')                    AS editions,
  STRING_AGG(DISTINCT i.version, ', ')                    AS versions,
  MAX(i.last_seen)                                        AS instances_last_seen
FROM   oracle.oracle_servers s
LEFT   JOIN LATERAL (
  SELECT * FROM oracle.oracle_processors op
  WHERE  op.server_id = s.server_id
  ORDER  BY op.recorded_at DESC
  LIMIT  1
) p ON TRUE
LEFT   JOIN oracle.oracle_instances i ON i.server_id = s.server_id AND i.is_active = TRUE
GROUP  BY s.server_id, s.hostname, s.fqdn, s.environment, s.os_distribution,
          s.os_version, s.is_active, s.last_seen,
          p.cpu_model, p.cpu_sockets, p.cores_per_socket, p.total_physical_cores,
          p.virt_type, p.is_vmware;

-- =============================================================================
-- Helios SAM Tool — Full Schema (single-file fresh install)
-- =============================================================================
-- Run order for a fresh install:
--   1. psql $DSN -f database/00_full_schema.sql      ← this file
--   2. psql $DSN -f database/02_shared_schema.sql
--   3. psql $DSN -f database/03_client_template_functions.sql
--   4. Provision clients:  SELECT sam_admin.provision_client('acme','Acme Corp');
--
-- This file consolidates:
--   01_admin_schema.sql + migrations 01, 02, 04, 06, 07, 08, 09, 10, 11, 12
-- Migration 03 (data-only tuning-pack rename) is intentionally excluded.
-- Migration 05 (NUP view rebuild) is superseded by install_client_tables() calling
--   install_license_position_view() — no standalone step needed on a fresh install.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- SCHEMAS
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS sam_admin;
CREATE SCHEMA IF NOT EXISTS shared;
SET search_path = sam_admin, public;

-- ---------------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE sam_admin.app_role AS ENUM (
    'superadmin',
    'contracting',
    'dba',
    'client'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE sam_admin.auth_method AS ENUM ('local', 'active_directory');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------------
-- CLIENT REGISTRY
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.clients (
  client_id       SERIAL PRIMARY KEY,
  client_code     TEXT NOT NULL UNIQUE,
  client_name     TEXT NOT NULL,
  schema_name     TEXT NOT NULL UNIQUE,
  contact_name    TEXT,
  contact_email   TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  notes           TEXT,
  CONSTRAINT chk_code   CHECK (client_code ~ '^[a-z0-9_]+$'),
  CONSTRAINT chk_schema CHECK (schema_name ~ '^client_[a-z0-9_]+$')
);

-- ---------------------------------------------------------------------------
-- DISCOVERY RUNS
-- (Full version from migration 10 — supersedes the stub in 01_admin_schema.sql)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.discovery_runs (
    run_id           SERIAL PRIMARY KEY,
    client_id        INTEGER NOT NULL REFERENCES sam_admin.clients(client_id) ON DELETE CASCADE,
    client_schema    TEXT    NOT NULL,
    discovery_source TEXT    NOT NULL,
    started_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at      TIMESTAMPTZ,
    servers_seen     INTEGER NOT NULL DEFAULT 0,
    servers_new      INTEGER NOT NULL DEFAULT 0,
    servers_updated  INTEGER NOT NULL DEFAULT 0,
    servers_conflict INTEGER NOT NULL DEFAULT 0,
    run_host         TEXT,
    notes            TEXT,
    run_status       TEXT NOT NULL DEFAULT 'running'
                     CHECK (run_status IN ('running','completed','failed'))
);

CREATE INDEX IF NOT EXISTS idx_disc_runs_client  ON sam_admin.discovery_runs (client_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_disc_runs_source  ON sam_admin.discovery_runs (discovery_source, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_disc_runs_status  ON sam_admin.discovery_runs (run_status);

-- ---------------------------------------------------------------------------
-- RBAC: APP USERS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.app_users (
  user_id         SERIAL PRIMARY KEY,
  username        TEXT NOT NULL UNIQUE,
  display_name    TEXT,
  email           TEXT,
  password_hash   TEXT,
  role            sam_admin.app_role NOT NULL DEFAULT 'client',
  client_id       INTEGER REFERENCES sam_admin.clients(client_id) ON DELETE SET NULL,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  auth_method     sam_admin.auth_method NOT NULL DEFAULT 'local',
  ad_username     TEXT,
  ad_groups       TEXT[],
  force_password_change BOOLEAN NOT NULL DEFAULT FALSE,
  last_login      TIMESTAMPTZ,
  created_by      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_app_users_username    ON sam_admin.app_users (username);
CREATE INDEX IF NOT EXISTS idx_app_users_ad_username ON sam_admin.app_users (ad_username)
  WHERE ad_username IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_app_users_client      ON sam_admin.app_users (client_id)
  WHERE client_id IS NOT NULL;

CREATE OR REPLACE FUNCTION sam_admin.touch_app_user()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END; $$;

DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'sam_admin' AND table_name = 'app_users'
  ) THEN
    DROP TRIGGER IF EXISTS trg_app_user_updated ON sam_admin.app_users;
  END IF;
END $$;
CREATE TRIGGER trg_app_user_updated
  BEFORE UPDATE ON sam_admin.app_users
  FOR EACH ROW EXECUTE FUNCTION sam_admin.touch_app_user();

INSERT INTO sam_admin.app_users (username, display_name, role, auth_method, created_by)
VALUES ('admin', 'Administrator', 'superadmin', 'local', 'schema-install')
ON CONFLICT (username) DO NOTHING;

-- ---------------------------------------------------------------------------
-- LICENCE SNAPSHOTS & AUDIT LOG (migration 07)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.licence_snapshots (
  snapshot_id    SERIAL PRIMARY KEY,
  client_id      INTEGER NOT NULL REFERENCES sam_admin.clients(client_id) ON DELETE CASCADE,
  snapshot_month DATE    NOT NULL,
  taken_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  taken_by       TEXT NOT NULL,
  note           TEXT,
  UNIQUE (client_id, snapshot_month)
);

CREATE TABLE IF NOT EXISTS sam_admin.licence_snapshot_lines (
  line_id            SERIAL PRIMARY KEY,
  snapshot_id        INTEGER NOT NULL
                       REFERENCES sam_admin.licence_snapshots(snapshot_id) ON DELETE CASCADE,
  hostname           TEXT,
  environment        TEXT,
  product_family     TEXT,
  product_detail     TEXT,
  licence_metric     TEXT,
  licences_required  NUMERIC,
  licences_assigned  NUMERIC,
  surplus_deficit    NUMERIC,
  compliance_status  TEXT,
  csi_number         TEXT,
  contract_ref       TEXT
);

CREATE INDEX IF NOT EXISTS idx_snap_lines_snapshot
  ON sam_admin.licence_snapshot_lines (snapshot_id);

CREATE TABLE IF NOT EXISTS sam_admin.audit_log (
  audit_id      BIGSERIAL PRIMARY KEY,
  username      TEXT NOT NULL,
  user_role     TEXT,
  action        TEXT NOT NULL,
  entity_type   TEXT,
  entity_id     TEXT,
  entity_name   TEXT,
  client_schema TEXT,
  old_values    JSONB,
  new_values    JSONB,
  ip_address    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_username   ON sam_admin.audit_log (username);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON sam_admin.audit_log (created_at);
CREATE INDEX IF NOT EXISTS idx_audit_log_action     ON sam_admin.audit_log (action);

CREATE OR REPLACE FUNCTION sam_admin.purge_old_audit_data()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_snap_deleted  INTEGER;
  v_audit_deleted INTEGER;
BEGIN
  DELETE FROM sam_admin.licence_snapshots
  WHERE taken_at < NOW() - INTERVAL '24 months';
  GET DIAGNOSTICS v_snap_deleted = ROW_COUNT;

  DELETE FROM sam_admin.audit_log
  WHERE created_at < NOW() - INTERVAL '6 months';
  GET DIAGNOSTICS v_audit_deleted = ROW_COUNT;

  RETURN FORMAT('Purged %s snapshot(s) and %s audit log row(s)', v_snap_deleted, v_audit_deleted);
END; $$;

-- ---------------------------------------------------------------------------
-- ASSIGNMENT REQUESTS (migration 08)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.assignment_requests (
    request_id        SERIAL PRIMARY KEY,
    client_id         INTEGER NOT NULL REFERENCES sam_admin.clients(client_id) ON DELETE CASCADE,
    client_schema     TEXT    NOT NULL,
    server_id         INTEGER NOT NULL,
    hostname          TEXT    NOT NULL,
    environment       TEXT,
    csi_id            INTEGER NOT NULL,
    csi_number        TEXT    NOT NULL,
    product_family    TEXT    NOT NULL,
    product_detail    TEXT,
    licences_consumed NUMERIC(10,2),
    notes             TEXT,
    proposed_by       TEXT    NOT NULL,
    proposed_by_role  TEXT    NOT NULL,
    proposed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    request_type      TEXT    NOT NULL DEFAULT 'assign'
                      CHECK (request_type IN ('assign','remove')),
    map_id_to_remove  INTEGER,
    status            TEXT    NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','approved','rejected','withdrawn')),
    reviewed_by       TEXT,
    reviewed_at       TIMESTAMPTZ,
    review_note       TEXT,
    applied_at        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_asgn_req_status ON sam_admin.assignment_requests (status, proposed_at DESC);
CREATE INDEX IF NOT EXISTS idx_asgn_req_client ON sam_admin.assignment_requests (client_id, status);

-- ---------------------------------------------------------------------------
-- FINOPS POOL SNAPSHOTS (migration 12)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.finops_pool_snapshots (
  snapshot_id    SERIAL PRIMARY KEY,
  snapshot_month DATE        NOT NULL,
  taken_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  taken_by       TEXT        NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_finops_pool_snap_month
  ON sam_admin.finops_pool_snapshots (snapshot_month);

CREATE TABLE IF NOT EXISTS sam_admin.finops_pool_snapshot_lines (
  line_id        SERIAL PRIMARY KEY,
  snapshot_id    INTEGER NOT NULL
                   REFERENCES sam_admin.finops_pool_snapshots(snapshot_id) ON DELETE CASCADE,
  client_id      INTEGER NOT NULL REFERENCES sam_admin.clients(client_id) ON DELETE CASCADE,
  client_name    TEXT    NOT NULL,
  csi_number     TEXT    NOT NULL,
  contract_name  TEXT,
  product_name   TEXT,
  licences_used  NUMERIC NOT NULL DEFAULT 0,
  unit_price     NUMERIC NOT NULL DEFAULT 0,
  monthly_cost   NUMERIC NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_finops_pool_snap_lines
  ON sam_admin.finops_pool_snapshot_lines (snapshot_id);

-- ---------------------------------------------------------------------------
-- VMWARE CLUSTER INFRASTRUCTURE
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.vmware_clusters (
  cluster_id       SERIAL PRIMARY KEY,
  cluster_name     TEXT NOT NULL,
  vcenter_host     TEXT NOT NULL,
  datacenter       TEXT,
  client_id        INTEGER REFERENCES sam_admin.clients (client_id) ON DELETE SET NULL,
  discovery_run_id TEXT,
  last_seen        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (vcenter_host, cluster_name)
);

CREATE TABLE IF NOT EXISTS sam_admin.vmware_hosts (
  host_id          SERIAL PRIMARY KEY,
  cluster_id       INTEGER NOT NULL
                     REFERENCES sam_admin.vmware_clusters (cluster_id) ON DELETE CASCADE,
  hostname         TEXT NOT NULL,
  cpu_model        TEXT,
  cpu_sockets      INTEGER NOT NULL DEFAULT 1,
  cores_per_socket INTEGER NOT NULL DEFAULT 1,
  total_cores      INTEGER GENERATED ALWAYS AS (cpu_sockets * cores_per_socket) STORED,
  memory_gb        NUMERIC(10,2),
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  discovery_run_id TEXT,
  last_seen        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (cluster_id, hostname)
);

CREATE TABLE IF NOT EXISTS sam_admin.vmware_vms (
  vm_id                   SERIAL PRIMARY KEY,
  cluster_id              INTEGER NOT NULL
                            REFERENCES sam_admin.vmware_clusters (cluster_id) ON DELETE CASCADE,
  host_id                 INTEGER
                            REFERENCES sam_admin.vmware_hosts (host_id) ON DELETE SET NULL,
  vm_name                 TEXT NOT NULL,
  vm_uuid                 TEXT UNIQUE,
  guest_hostname          TEXT,
  guest_ip                TEXT,
  power_state             TEXT,
  vcpu_count              INTEGER,
  memory_mb               INTEGER,
  has_oracle_db           BOOLEAN NOT NULL DEFAULT FALSE,
  has_oracle_wls          BOOLEAN NOT NULL DEFAULT FALSE,
  has_oracle_java         BOOLEAN NOT NULL DEFAULT FALSE,
  discovery_run_id        TEXT,
  last_seen               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (cluster_id, vm_name)
);

CREATE INDEX IF NOT EXISTS idx_vmw_cluster_client ON sam_admin.vmware_clusters (client_id);
CREATE INDEX IF NOT EXISTS idx_vmw_host_cluster   ON sam_admin.vmware_hosts    (cluster_id);
CREATE INDEX IF NOT EXISTS idx_vmw_vm_cluster     ON sam_admin.vmware_vms      (cluster_id);
CREATE INDEX IF NOT EXISTS idx_vmw_vm_host        ON sam_admin.vmware_vms      (host_id);
CREATE INDEX IF NOT EXISTS idx_vmw_vm_hostname    ON sam_admin.vmware_vms      (guest_hostname);

CREATE OR REPLACE VIEW sam_admin.vmware_licence_exposure AS
SELECT
  vc.cluster_id,
  vc.cluster_name,
  vc.vcenter_host,
  vc.datacenter,
  c.client_code,
  COUNT(DISTINCT vh.host_id)                          AS host_count,
  SUM(vh.cpu_sockets)                                 AS total_sockets,
  SUM(vh.total_cores)                                 AS total_physical_cores,
  COUNT(DISTINCT vm.vm_id) FILTER (WHERE vm.has_oracle_db)   AS oracle_db_vm_count,
  COUNT(DISTINCT vm.vm_id) FILTER (WHERE vm.has_oracle_wls)  AS oracle_wls_vm_count,
  COUNT(DISTINCT vm.vm_id) FILTER (WHERE vm.has_oracle_java) AS oracle_java_vm_count,
  BOOL_OR(vm.has_oracle_db OR vm.has_oracle_wls OR vm.has_oracle_java) AS has_oracle_workloads,
  vc.last_seen
FROM   sam_admin.vmware_clusters vc
JOIN   sam_admin.vmware_hosts    vh ON vh.cluster_id = vc.cluster_id AND vh.is_active
LEFT   JOIN sam_admin.vmware_vms vm ON vm.cluster_id = vc.cluster_id
LEFT   JOIN sam_admin.clients    c  ON c.client_id   = vc.client_id
GROUP  BY vc.cluster_id, vc.cluster_name, vc.vcenter_host, vc.datacenter,
          c.client_code, vc.last_seen;

-- ---------------------------------------------------------------------------
-- ALERT CHANNELS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.alert_channels (
  channel_id    SERIAL PRIMARY KEY,
  channel_type  TEXT NOT NULL CHECK (channel_type IN ('email', 'slack', 'teams')),
  channel_name  TEXT NOT NULL,
  config        JSONB NOT NULL DEFAULT '{}',
  enabled       BOOLEAN NOT NULL DEFAULT TRUE,
  min_severity  TEXT NOT NULL DEFAULT 'MEDIUM'
                  CHECK (min_severity IN ('LOW', 'MEDIUM', 'HIGH')),
  last_sent_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- log_discovery_run() helper (migration 10)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.log_discovery_run(
    p_schema          TEXT,
    p_source          TEXT,
    p_servers_seen    INTEGER DEFAULT 0,
    p_servers_new     INTEGER DEFAULT 0,
    p_servers_updated INTEGER DEFAULT 0,
    p_servers_conflict INTEGER DEFAULT 0,
    p_run_host        TEXT    DEFAULT NULL,
    p_notes           TEXT    DEFAULT NULL,
    p_status          TEXT    DEFAULT 'completed',
    p_started_at      TIMESTAMPTZ DEFAULT NULL
)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_client_id INTEGER;
    v_run_id    INTEGER;
BEGIN
    SELECT client_id INTO v_client_id
    FROM sam_admin.clients WHERE schema_name = p_schema AND is_active;

    IF v_client_id IS NULL THEN
        RAISE EXCEPTION 'No active client found for schema %', p_schema;
    END IF;

    INSERT INTO sam_admin.discovery_runs
        (client_id, client_schema, discovery_source,
         started_at, finished_at,
         servers_seen, servers_new, servers_updated, servers_conflict,
         run_host, notes, run_status)
    VALUES
        (v_client_id, p_schema, p_source,
         COALESCE(p_started_at, NOW()), NOW(),
         p_servers_seen, p_servers_new, p_servers_updated, p_servers_conflict,
         p_run_host, p_notes, p_status)
    RETURNING run_id INTO v_run_id;

    RETURN v_run_id;
END; $$;

-- ---------------------------------------------------------------------------
-- register_server() — cross-schema discovery upsert (migration 09)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.register_server(
    p_schema           TEXT,
    p_hostname         TEXT,
    p_source           TEXT,
    p_fqdn             TEXT    DEFAULT NULL,
    p_ip_address       TEXT    DEFAULT NULL,
    p_os_family        TEXT    DEFAULT NULL,
    p_os_distribution  TEXT    DEFAULT NULL,
    p_os_version       TEXT    DEFAULT NULL,
    p_environment      TEXT    DEFAULT NULL,
    p_total_ram_mb     INTEGER DEFAULT NULL,
    p_datacenter       TEXT    DEFAULT NULL,
    p_physical_cores   INTEGER DEFAULT NULL,
    p_cpu_sockets      INTEGER DEFAULT NULL,
    p_cores_per_socket INTEGER DEFAULT NULL,
    p_notes            TEXT    DEFAULT NULL
)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_ip         INET;
    v_short      TEXT;
    v_fqdn_norm  TEXT;
    v_existing   RECORD;
    v_match_id   INTEGER := NULL;
    v_match_how  TEXT;
    v_server_id  INTEGER;
    v_result     TEXT;
    v_conflict   BOOLEAN := FALSE;
    v_conflict_detail TEXT := NULL;
BEGIN
    p_hostname := TRIM(LOWER(p_hostname));
    v_short := SPLIT_PART(p_hostname, '.', 1);
    v_fqdn_norm := COALESCE(
        NULLIF(TRIM(LOWER(p_fqdn)), ''),
        CASE WHEN p_hostname LIKE '%.%' THEN p_hostname ELSE NULL END
    );
    IF v_fqdn_norm IS NOT NULL THEN
        p_hostname := v_short;
    END IF;
    IF p_ip_address IS NOT NULL AND TRIM(p_ip_address) <> '' THEN
        BEGIN
            v_ip := TRIM(p_ip_address)::INET;
        EXCEPTION WHEN OTHERS THEN
            v_ip := NULL;
        END;
    END IF;

    EXECUTE format('ALTER TABLE %I.oracle_servers ADD COLUMN IF NOT EXISTS discovery_source    TEXT', p_schema);
    EXECUTE format('ALTER TABLE %I.oracle_servers ADD COLUMN IF NOT EXISTS discovery_conflict  BOOLEAN NOT NULL DEFAULT FALSE', p_schema);
    EXECUTE format('ALTER TABLE %I.oracle_servers ADD COLUMN IF NOT EXISTS conflict_detail     TEXT', p_schema);

    EXECUTE format('SELECT server_id FROM %I.oracle_servers WHERE hostname = $1 LIMIT 1', p_schema)
    INTO v_match_id USING p_hostname;
    IF v_match_id IS NOT NULL THEN v_match_how := 'hostname_exact'; END IF;

    IF v_match_id IS NULL THEN
        EXECUTE format('SELECT server_id FROM %I.oracle_servers WHERE SPLIT_PART(hostname,''.'',1) = $1 OR SPLIT_PART(COALESCE(fqdn,''''),''.'',1) = $1 LIMIT 1', p_schema)
        INTO v_match_id USING v_short;
        IF v_match_id IS NOT NULL THEN v_match_how := 'short_name'; END IF;
    END IF;

    IF v_match_id IS NULL AND v_fqdn_norm IS NOT NULL THEN
        EXECUTE format('SELECT server_id FROM %I.oracle_servers WHERE fqdn = $1 OR hostname = $1 LIMIT 1', p_schema)
        INTO v_match_id USING v_fqdn_norm;
        IF v_match_id IS NOT NULL THEN v_match_how := 'fqdn'; END IF;
    END IF;

    IF v_match_id IS NULL AND v_ip IS NOT NULL THEN
        EXECUTE format('SELECT server_id FROM %I.oracle_servers WHERE ip_address = $1 LIMIT 1', p_schema)
        INTO v_match_id USING v_ip;
        IF v_match_id IS NOT NULL THEN v_match_how := 'ip_address'; END IF;
    END IF;

    IF v_match_id IS NOT NULL AND v_match_how <> 'hostname_exact' THEN
        DECLARE v_other INTEGER; BEGIN
            EXECUTE format('SELECT server_id FROM %I.oracle_servers WHERE hostname = $1 AND server_id <> $2 LIMIT 1', p_schema)
            INTO v_other USING p_hostname, v_match_id;
            IF v_other IS NOT NULL THEN
                v_conflict := TRUE;
                v_conflict_detail := format('Incoming hostname "%s" (source: %s) collides with server_id %s but was matched to server_id %s via %s. Review and merge manually.', p_hostname, p_source, v_other, v_match_id, v_match_how);
                RETURN 'conflict:' || v_conflict_detail;
            END IF;
        END;
    END IF;

    IF v_match_id IS NULL THEN
        EXECUTE format($q$
            INSERT INTO %I.oracle_servers
              (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
               environment, total_ram_mb, datacenter, last_discovery_run, discovery_source, first_seen, last_seen)
            VALUES ($1,$2,$3,$4,$5,$6, COALESCE($7,'unknown')::%I.environment_type, $8,$9,$10,$11,NOW(),NOW())
            RETURNING server_id
        $q$, p_schema, p_schema)
        INTO v_server_id
        USING p_hostname, v_fqdn_norm, v_ip, p_os_family, p_os_distribution, p_os_version,
              p_environment, p_total_ram_mb, p_datacenter, p_notes, p_source;
        v_result := 'inserted:' || v_server_id;
    ELSE
        EXECUTE format($q$
            UPDATE %I.oracle_servers SET
              fqdn             = COALESCE($2, fqdn),
              ip_address       = COALESCE($3, ip_address),
              os_family        = COALESCE($4, os_family),
              os_distribution  = COALESCE($5, os_distribution),
              os_version       = COALESCE($6, os_version),
              environment      = CASE WHEN $7 IS NOT NULL THEN $7::%I.environment_type ELSE environment END,
              total_ram_mb     = COALESCE($8, total_ram_mb),
              datacenter       = COALESCE($9, datacenter),
              last_seen        = NOW(),
              last_discovery_run = COALESCE($10, last_discovery_run),
              discovery_source = $11,
              discovery_conflict = $12,
              conflict_detail  = COALESCE($13, conflict_detail)
            WHERE server_id = $1
        $q$, p_schema, p_schema)
        USING v_match_id, v_fqdn_norm, v_ip, p_os_family, p_os_distribution, p_os_version,
              p_environment, p_total_ram_mb, p_datacenter, p_notes, p_source, v_conflict, v_conflict_detail;
        v_server_id := v_match_id;
        v_result := 'updated:' || v_server_id || ':via_' || v_match_how;
    END IF;

    IF p_physical_cores IS NOT NULL OR p_cpu_sockets IS NOT NULL THEN
        DECLARE
            v_sockets INTEGER := COALESCE(p_cpu_sockets, 1);
            v_cps     INTEGER := COALESCE(p_cores_per_socket,
                CASE WHEN p_cpu_sockets IS NOT NULL AND p_physical_cores IS NOT NULL
                     THEN p_physical_cores / NULLIF(p_cpu_sockets, 0) ELSE p_physical_cores END);
        BEGIN
            EXECUTE format($q$
                INSERT INTO %I.oracle_processors (server_id, cpu_model, cpu_sockets, cores_per_socket)
                VALUES ($1, 'Unknown', $2, $3)
                ON CONFLICT (server_id, cpu_model) DO UPDATE
                  SET cpu_sockets = EXCLUDED.cpu_sockets, cores_per_socket = EXCLUDED.cores_per_socket
            $q$, p_schema)
            USING v_server_id, v_sockets, COALESCE(v_cps, 1);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END IF;

    RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION sam_admin.list_conflicts()
RETURNS TABLE (
    client_name TEXT, schema_name TEXT,
    server_id INTEGER, hostname TEXT, fqdn TEXT,
    ip_address TEXT, discovery_source TEXT,
    last_seen TIMESTAMPTZ, conflict_detail TEXT
)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; BEGIN
    FOR r IN SELECT c.schema_name, c.client_name FROM sam_admin.clients c WHERE c.is_active LOOP
        BEGIN
            RETURN QUERY EXECUTE format(
                'SELECT %L::TEXT, %L::TEXT, server_id, hostname, fqdn, ip_address::TEXT,
                        discovery_source, last_seen, conflict_detail
                 FROM %I.oracle_servers WHERE discovery_conflict = TRUE',
                r.client_name, r.schema_name, r.schema_name);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
END; $$;

-- ---------------------------------------------------------------------------
-- PROVISION CLIENT SCHEMA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.provision_client(
  p_code TEXT,
  p_name TEXT,
  p_contact_email TEXT DEFAULT NULL
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_schema TEXT := 'client_' || p_code;
  v_client_id INTEGER;
BEGIN
  IF p_code !~ '^[a-z0-9_]+$' THEN
    RAISE EXCEPTION 'client_code must be lowercase alphanumeric/underscore only: %', p_code;
  END IF;

  INSERT INTO sam_admin.clients (client_code, client_name, schema_name, contact_email)
  VALUES (p_code, p_name, v_schema, p_contact_email)
  ON CONFLICT (client_code) DO UPDATE
    SET client_name   = EXCLUDED.client_name,
        contact_email = COALESCE(EXCLUDED.contact_email, sam_admin.clients.contact_email)
  RETURNING client_id INTO v_client_id;

  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);
  EXECUTE format('COMMENT ON SCHEMA %I IS %L', v_schema,
    format('SAM client schema for %s (id=%s)', p_name, v_client_id));

  PERFORM sam_admin.install_client_tables(v_schema);

  RETURN format('Client "%s" provisioned. Schema: %s', p_name, v_schema);
END; $$;

-- ---------------------------------------------------------------------------
-- INSTALL CLIENT TABLES
-- Includes all columns from migrations 01, 09 (discovery_source columns)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.install_client_tables(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN

  BEGIN
    EXECUTE format(
      'CREATE TYPE %I.environment_type AS ENUM
       (''production'',''non_production'',''development'',''test'',''dr'',''unknown'')',
      p_schema);
  EXCEPTION WHEN duplicate_object THEN NULL; END;

  BEGIN
    EXECUTE format(
      'CREATE TYPE %I.virt_type AS ENUM
       (''physical'',''vmware'',''hyperv'',''kvm'',''xen'',''lpar'',''zone'',''container'',''unknown'')',
      p_schema);
  EXCEPTION WHEN duplicate_object THEN NULL; END;

  -- oracle_servers (includes discovery_source columns from migration 09)
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.oracle_servers (
      server_id                SERIAL PRIMARY KEY,
      hostname                 TEXT NOT NULL UNIQUE,
      fqdn                     TEXT,
      ip_address               INET,
      os_family                TEXT,
      os_distribution          TEXT,
      os_version               TEXT,
      environment              %I.environment_type NOT NULL DEFAULT 'unknown',
      criticality              TEXT,
      total_ram_mb             INTEGER,
      datacenter               TEXT,
      is_active                BOOLEAN NOT NULL DEFAULT TRUE,
      first_seen               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_seen                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_discovery_run       TEXT,
      notes                    TEXT,
      licence_metric_override  TEXT
        CHECK (licence_metric_override IN ('processor_perpetual','named_user_plus')),
      discovery_source         TEXT,
      discovery_conflict       BOOLEAN NOT NULL DEFAULT FALSE,
      conflict_detail          TEXT
    )
  $sql$, p_schema, p_schema);

  -- oracle_processors
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.oracle_processors (
      proc_id               SERIAL PRIMARY KEY,
      server_id             INTEGER NOT NULL
                              REFERENCES %I.oracle_servers (server_id) ON DELETE CASCADE,
      cpu_model             TEXT NOT NULL,
      cpu_architecture      TEXT,
      cpu_sockets           INTEGER NOT NULL DEFAULT 1,
      cores_per_socket      INTEGER NOT NULL DEFAULT 1,
      threads_per_core      INTEGER NOT NULL DEFAULT 1,
      total_physical_cores  INTEGER GENERATED ALWAYS AS (cpu_sockets * cores_per_socket) STORED,
      virt_type             %I.virt_type NOT NULL DEFAULT 'unknown',
      is_vmware             BOOLEAN NOT NULL DEFAULT FALSE,
      vcpu_count            INTEGER,
      recorded_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id      TEXT
    )
  $sql$, p_schema, p_schema, p_schema);

  -- oracle_instances
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.oracle_instances (
      instance_id       SERIAL PRIMARY KEY,
      server_id         INTEGER NOT NULL
                          REFERENCES %I.oracle_servers (server_id) ON DELETE CASCADE,
      oracle_sid        TEXT NOT NULL,
      db_name           TEXT,
      oracle_home       TEXT,
      edition           TEXT,
      db_version        TEXT,
      platform_name     TEXT,
      created_date      DATE,
      autostart         BOOLEAN,
      is_active         BOOLEAN NOT NULL DEFAULT TRUE,
      first_seen        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_seen         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id  TEXT,
      UNIQUE (server_id, oracle_sid)
    )
  $sql$, p_schema, p_schema);

  -- oracle_options
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.oracle_options (
      option_id         SERIAL PRIMARY KEY,
      instance_id       INTEGER NOT NULL
                          REFERENCES %I.oracle_instances (instance_id) ON DELETE CASCADE,
      option_name       TEXT NOT NULL,
      option_version    TEXT,
      status            TEXT,
      discovery_run_id  TEXT,
      recorded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  $sql$, p_schema, p_schema);

  -- wls_domains
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.wls_domains (
      domain_id         SERIAL PRIMARY KEY,
      server_id         INTEGER NOT NULL
                          REFERENCES %I.oracle_servers (server_id) ON DELETE CASCADE,
      domain_name       TEXT NOT NULL,
      domain_home       TEXT,
      wls_version       TEXT,
      wls_edition       TEXT,
      admin_server_host TEXT,
      admin_server_port INTEGER,
      is_active         BOOLEAN NOT NULL DEFAULT TRUE,
      first_seen        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_seen         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id  TEXT,
      UNIQUE (server_id, domain_name)
    )
  $sql$, p_schema, p_schema);

  -- wls_managed_servers
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.wls_managed_servers (
      managed_server_id   SERIAL PRIMARY KEY,
      domain_id           INTEGER NOT NULL
                            REFERENCES %I.wls_domains (domain_id) ON DELETE CASCADE,
      server_id           INTEGER NOT NULL
                            REFERENCES %I.oracle_servers (server_id) ON DELETE CASCADE,
      managed_server_name TEXT NOT NULL,
      listen_port         INTEGER,
      ssl_port            INTEGER,
      cluster_name        TEXT,
      machine_name        TEXT,
      state               TEXT,
      is_active           BOOLEAN NOT NULL DEFAULT TRUE,
      last_seen           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id    TEXT
    )
  $sql$, p_schema, p_schema, p_schema);

  -- wls_installed_products
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.wls_installed_products (
      product_id        SERIAL PRIMARY KEY,
      domain_id         INTEGER NOT NULL
                          REFERENCES %I.wls_domains (domain_id) ON DELETE CASCADE,
      product_name      TEXT NOT NULL,
      product_version   TEXT,
      home_path         TEXT,
      discovery_run_id  TEXT,
      recorded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  $sql$, p_schema, p_schema);

  -- discovery_changelog
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.discovery_changelog (
      change_id         SERIAL PRIMARY KEY,
      detected_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id  TEXT,
      server_id         INTEGER
                          REFERENCES %I.oracle_servers (server_id) ON DELETE SET NULL,
      hostname          TEXT,
      change_category   TEXT NOT NULL,
      change_type       TEXT NOT NULL,
      severity          TEXT NOT NULL DEFAULT 'MEDIUM',
      object_name       TEXT NOT NULL,
      field_changed     TEXT,
      old_value         TEXT,
      new_value         TEXT,
      licence_impact    TEXT,
      acknowledged      BOOLEAN NOT NULL DEFAULT FALSE,
      acknowledged_by   TEXT,
      acknowledged_at   TIMESTAMPTZ,
      notes             TEXT
    )
  $sql$, p_schema, p_schema);

  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_chg_server   ON %I.discovery_changelog (server_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_chg_run      ON %I.discovery_changelog (discovery_run_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_chg_ack      ON %I.discovery_changelog (acknowledged)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_chg_sev      ON %I.discovery_changelog (severity)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_chg_detected ON %I.discovery_changelog (detected_at DESC)', p_schema, p_schema);

  -- server_csi_map
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.server_csi_map (
      map_id              SERIAL PRIMARY KEY,
      server_id           INTEGER NOT NULL
                            REFERENCES %I.oracle_servers (server_id) ON DELETE CASCADE,
      csi_id              INTEGER NOT NULL
                            REFERENCES shared.csi_contracts (csi_id),
      line_id             INTEGER
                            REFERENCES shared.license_entitlement_lines (line_id),
      product_family      TEXT NOT NULL,
      product_detail      TEXT,
      licences_consumed   NUMERIC(10,2),
      effective_date      DATE NOT NULL DEFAULT CURRENT_DATE,
      notes               TEXT,
      assigned_by         TEXT,
      created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  $sql$, p_schema, p_schema);

  EXECUTE format($sql$
    CREATE UNIQUE INDEX IF NOT EXISTS uix_%s_server_csi_line
      ON %I.server_csi_map (server_id, csi_id, product_family, COALESCE(product_detail, ''))
  $sql$, p_schema, p_schema);

  -- oracle_rac_nodes
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.oracle_rac_nodes (
      rac_node_id       SERIAL PRIMARY KEY,
      instance_id       INTEGER NOT NULL
                          REFERENCES %I.oracle_instances (instance_id) ON DELETE CASCADE,
      server_id         INTEGER NOT NULL
                          REFERENCES %I.oracle_servers (server_id) ON DELETE CASCADE,
      node_name         TEXT NOT NULL,
      node_number       INTEGER,
      instance_name     TEXT,
      is_active         BOOLEAN NOT NULL DEFAULT TRUE,
      last_seen         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id  TEXT,
      UNIQUE (instance_id, node_name)
    )
  $sql$, p_schema, p_schema, p_schema);

  -- oracle_pdbs
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.oracle_pdbs (
      pdb_id                       SERIAL PRIMARY KEY,
      instance_id                  INTEGER NOT NULL
                                     REFERENCES %I.oracle_instances (instance_id) ON DELETE CASCADE,
      pdb_name                     TEXT NOT NULL,
      pdb_con_id                   INTEGER,
      open_mode                    TEXT,
      restricted                   TEXT,
      is_cdb_root                  BOOLEAN NOT NULL DEFAULT FALSE,
      requires_multitenant_licence BOOLEAN NOT NULL DEFAULT FALSE,
      last_seen                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id             TEXT,
      UNIQUE (instance_id, pdb_name)
    )
  $sql$, p_schema, p_schema);

  -- oracle_nup_users
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.oracle_nup_users (
      nup_id            SERIAL PRIMARY KEY,
      instance_id       INTEGER NOT NULL
                          REFERENCES %I.oracle_instances (instance_id) ON DELETE CASCADE,
      snapshot_date     DATE NOT NULL DEFAULT CURRENT_DATE,
      active_user_count INTEGER NOT NULL DEFAULT 0,
      total_user_count  INTEGER NOT NULL DEFAULT 0,
      locked_user_count INTEGER NOT NULL DEFAULT 0,
      sample_user_list  TEXT[],
      discovery_run_id  TEXT,
      recorded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  $sql$, p_schema, p_schema);

  -- java_installations (includes licence_exempt columns from migration 01)
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.java_installations (
      java_id            SERIAL PRIMARY KEY,
      server_id          INTEGER NOT NULL
                           REFERENCES %I.oracle_servers (server_id) ON DELETE CASCADE,
      java_home          TEXT NOT NULL,
      java_vendor        TEXT,
      java_version       TEXT,
      java_major_version INTEGER,
      java_edition       TEXT,
      is_oracle_jdk      BOOLEAN NOT NULL DEFAULT FALSE,
      requires_licence   BOOLEAN NOT NULL DEFAULT FALSE,
      licence_metric     TEXT,
      licence_exempt     BOOLEAN NOT NULL DEFAULT FALSE,
      exempt_reason      TEXT
                           CHECK (exempt_reason IN (
                             'oracle_oem', 'oracle_database_jvm', 'oracle_weblogic',
                             'oracle_fusion_middleware', 'oracle_forms_reports', 'custom'
                           )),
      exempt_notes       TEXT,
      exempt_set_by      TEXT,
      exempt_set_at      TIMESTAMPTZ,
      first_seen         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_seen          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id   TEXT,
      UNIQUE (server_id, java_home)
    )
  $sql$, p_schema, p_schema);

  -- mysql_installations
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.mysql_installations (
      mysql_id          SERIAL PRIMARY KEY,
      server_id         INTEGER NOT NULL
                          REFERENCES %I.oracle_servers (server_id) ON DELETE CASCADE,
      mysql_version     TEXT,
      mysql_edition     TEXT,
      install_path      TEXT,
      data_dir          TEXT,
      port              INTEGER,
      is_enterprise     BOOLEAN NOT NULL DEFAULT FALSE,
      requires_licence  BOOLEAN NOT NULL DEFAULT FALSE,
      first_seen        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_seen         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id  TEXT
    )
  $sql$, p_schema, p_schema);
  EXECUTE format($sql$
    CREATE UNIQUE INDEX IF NOT EXISTS mysql_installations_server_path_uidx
      ON %I.mysql_installations (server_id, COALESCE(install_path, 'unknown'))
  $sql$, p_schema);

  -- oci_instances
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.oci_instances (
      oci_id              SERIAL PRIMARY KEY,
      server_id           INTEGER
                            REFERENCES %I.oracle_servers (server_id) ON DELETE SET NULL,
      oci_instance_id     TEXT NOT NULL UNIQUE,
      display_name        TEXT,
      compartment_id      TEXT,
      compartment_name    TEXT,
      availability_domain TEXT,
      region              TEXT,
      shape               TEXT,
      ocpu_count          NUMERIC(10,2),
      memory_gb           NUMERIC(10,2),
      image_os            TEXT,
      lifecycle_state     TEXT,
      is_byol             BOOLEAN NOT NULL DEFAULT FALSE,
      oracle_db_edition   TEXT,
      private_ip          TEXT,
      public_ip           TEXT,
      first_seen          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_seen           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id    TEXT
    )
  $sql$, p_schema, p_schema);

  -- Indexes
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_proc_server   ON %I.oracle_processors (server_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_inst_server   ON %I.oracle_instances  (server_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_opt_inst      ON %I.oracle_options    (instance_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_wls_server    ON %I.wls_domains       (server_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_wls_ms_domain ON %I.wls_managed_servers (domain_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_scm_server    ON %I.server_csi_map    (server_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_scm_csi       ON %I.server_csi_map    (csi_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_scm_family    ON %I.server_csi_map    (product_family)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_rac_inst      ON %I.oracle_rac_nodes   (instance_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_pdb_inst      ON %I.oracle_pdbs        (instance_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_nup_inst      ON %I.oracle_nup_users   (instance_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_java_server   ON %I.java_installations (server_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_mysql_server  ON %I.mysql_installations(server_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_oci_server    ON %I.oci_instances      (server_id)', p_schema, p_schema);

  PERFORM sam_admin.install_license_position_view(p_schema);
  PERFORM sam_admin.install_license_options_view(p_schema);
  PERFORM sam_admin.install_server_coverage_view(p_schema);
  PERFORM sam_admin.install_changelog_objects(p_schema);
  PERFORM sam_admin.install_upsert_functions(p_schema);
  PERFORM sam_admin.install_extended_views(p_schema);

END; $$;

-- Placeholder stubs for view-installer functions — only created when absent.
-- On a fresh install 03_client_template_functions.sql must be run AFTER this
-- file to replace these stubs with the real implementations.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'sam_admin' AND p.proname = 'install_license_position_view') THEN
    EXECUTE $f$ CREATE FUNCTION sam_admin.install_license_position_view(p_schema TEXT) RETURNS VOID LANGUAGE plpgsql AS $b$ BEGIN NULL; END; $b$ $f$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'sam_admin' AND p.proname = 'install_license_options_view') THEN
    EXECUTE $f$ CREATE FUNCTION sam_admin.install_license_options_view(p_schema TEXT) RETURNS VOID LANGUAGE plpgsql AS $b$ BEGIN NULL; END; $b$ $f$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'sam_admin' AND p.proname = 'install_server_coverage_view') THEN
    EXECUTE $f$ CREATE FUNCTION sam_admin.install_server_coverage_view(p_schema TEXT) RETURNS VOID LANGUAGE plpgsql AS $b$ BEGIN NULL; END; $b$ $f$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'sam_admin' AND p.proname = 'install_changelog_objects') THEN
    EXECUTE $f$ CREATE FUNCTION sam_admin.install_changelog_objects(p_schema TEXT) RETURNS VOID LANGUAGE plpgsql AS $b$ BEGIN NULL; END; $b$ $f$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'sam_admin' AND p.proname = 'install_upsert_functions') THEN
    EXECUTE $f$ CREATE FUNCTION sam_admin.install_upsert_functions(p_schema TEXT) RETURNS VOID LANGUAGE plpgsql AS $b$ BEGIN NULL; END; $b$ $f$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'sam_admin' AND p.proname = 'install_extended_views') THEN
    EXECUTE $f$ CREATE FUNCTION sam_admin.install_extended_views(p_schema TEXT) RETURNS VOID LANGUAGE plpgsql AS $b$ BEGIN NULL; END; $b$ $f$;
  END IF;
END; $$;

-- ---------------------------------------------------------------------------
-- SHARED SCHEMA: ULA COVERED PRODUCTS (migration 04)
-- (shared schema tables that aren't in 02_shared_schema.sql)
-- ---------------------------------------------------------------------------
-- NOTE: Run 02_shared_schema.sql before this file to ensure shared.csi_contracts exists.
-- The block below runs safely if 02_shared_schema.sql has already been applied.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'shared' AND table_name = 'csi_contracts'
  ) THEN
    EXECUTE $sql$
      CREATE TABLE IF NOT EXISTS shared.ula_covered_products (
        id           SERIAL PRIMARY KEY,
        csi_id       INTEGER NOT NULL
                       REFERENCES shared.csi_contracts(csi_id) ON DELETE CASCADE,
        product_name TEXT    NOT NULL,
        UNIQUE (csi_id, product_name)
      )
    $sql$;
    EXECUTE $sql$
      CREATE INDEX IF NOT EXISTS idx_ula_covered_csi ON shared.ula_covered_products (csi_id)
    $sql$;
  ELSE
    RAISE NOTICE 'shared.csi_contracts not found — skipping ula_covered_products. Run 02_shared_schema.sql first, then re-run this file or migration 04.';
  END IF;
END; $$;

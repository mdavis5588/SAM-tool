-- =============================================================================
-- SAM Admin Schema
-- Manages client registry, schema provisioning, and discovery audit.
-- Run this FIRST, before any client or shared schema.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS sam_admin;
SET search_path = sam_admin, public;

-- ---------------------------------------------------------------------------
-- CLIENT REGISTRY
-- One row per managed client. The schema_name drives all dynamic SQL.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.clients (
  client_id       SERIAL PRIMARY KEY,
  client_code     TEXT NOT NULL UNIQUE,   -- short slug, used as schema name suffix
  client_name     TEXT NOT NULL,
  schema_name     TEXT NOT NULL UNIQUE,   -- e.g. 'client_acme'
  contact_name    TEXT,
  contact_email   TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  notes           TEXT,
  CONSTRAINT chk_code   CHECK (client_code ~ '^[a-z0-9_]+$'),
  CONSTRAINT chk_schema CHECK (schema_name ~ '^client_[a-z0-9_]+$')
);

-- ---------------------------------------------------------------------------
-- DISCOVERY RUNS AUDIT
-- Central audit log across all clients and all product types.
-- ---------------------------------------------------------------------------
CREATE TYPE sam_admin.product_type AS ENUM
  ('oracle_database', 'oracle_weblogic', 'oracle_java', 'mssql', 'vmware');

CREATE TABLE IF NOT EXISTS sam_admin.discovery_runs (
  run_id          TEXT PRIMARY KEY,
  client_id       INTEGER NOT NULL REFERENCES sam_admin.clients (client_id),
  product         sam_admin.product_type NOT NULL DEFAULT 'oracle_database',
  started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at    TIMESTAMPTZ,
  hosts_targeted  INTEGER,
  hosts_succeeded INTEGER,
  hosts_failed    INTEGER,
  triggered_by    TEXT,
  ansible_version TEXT,
  playbook        TEXT,
  notes           TEXT
);

CREATE INDEX idx_runs_client  ON sam_admin.discovery_runs (client_id);
CREATE INDEX idx_runs_product ON sam_admin.discovery_runs (product);
CREATE INDEX idx_runs_started ON sam_admin.discovery_runs (started_at DESC);

-- ---------------------------------------------------------------------------
-- PROVISION CLIENT SCHEMA
-- Creates a complete client schema from the template.
-- Call this once per new client:
--   SELECT sam_admin.provision_client('acme', 'Acme Corp');
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
  -- Validate code
  IF p_code !~ '^[a-z0-9_]+$' THEN
    RAISE EXCEPTION 'client_code must be lowercase alphanumeric/underscore only: %', p_code;
  END IF;

  -- Register client
  INSERT INTO sam_admin.clients (client_code, client_name, schema_name, contact_email)
  VALUES (p_code, p_name, v_schema, p_contact_email)
  RETURNING client_id INTO v_client_id;

  -- Create schema
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);

  -- Stamp schema with client metadata
  EXECUTE format(
    'COMMENT ON SCHEMA %I IS %L',
    v_schema,
    format('SAM client schema for %s (id=%s)', p_name, v_client_id)
  );

  -- Install all client tables into the new schema
  PERFORM sam_admin.install_client_tables(v_schema);

  RETURN format('Client "%s" provisioned. Schema: %s', p_name, v_schema);
END;
$$;

-- ---------------------------------------------------------------------------
-- INSTALL CLIENT TABLES
-- Called by provision_client. Creates all tables and views in a client schema.
-- Also called for schema migrations — idempotent via IF NOT EXISTS.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.install_client_tables(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN

  -- ENUM types (schema-qualified, created if absent)
  EXECUTE format($sql$
    DO $$ BEGIN
      CREATE TYPE %I.environment_type AS ENUM
        ('production','non_production','development','test','dr','unknown');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
  $sql$, p_schema);

  EXECUTE format($sql$
    DO $$ BEGIN
      CREATE TYPE %I.virt_type AS ENUM
        ('physical','vmware','hyperv','kvm','xen','lpar','zone','container','unknown');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
  $sql$, p_schema);

  -- oracle_servers
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.oracle_servers (
      server_id           SERIAL PRIMARY KEY,
      hostname            TEXT NOT NULL UNIQUE,
      fqdn                TEXT,
      ip_address          INET,
      os_family           TEXT,
      os_distribution     TEXT,
      os_version          TEXT,
      environment         %I.environment_type NOT NULL DEFAULT 'unknown',
      criticality         TEXT,
      total_ram_mb        INTEGER,
      datacenter          TEXT,
      is_active           BOOLEAN NOT NULL DEFAULT TRUE,
      first_seen          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_seen           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_discovery_run  TEXT,
      notes               TEXT
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
      wls_edition       TEXT,    -- WebLogic Server, WebLogic Suite, Coherence, etc.
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
      managed_server_id SERIAL PRIMARY KEY,
      domain_id         INTEGER NOT NULL
                          REFERENCES %I.wls_domains (domain_id) ON DELETE CASCADE,
      server_id         INTEGER NOT NULL
                          REFERENCES %I.oracle_servers (server_id) ON DELETE CASCADE,
      managed_server_name TEXT NOT NULL,
      listen_port       INTEGER,
      ssl_port          INTEGER,
      cluster_name      TEXT,
      machine_name      TEXT,
      state             TEXT,    -- RUNNING, SHUTDOWN, etc. from WLST
      is_active         BOOLEAN NOT NULL DEFAULT TRUE,
      last_seen         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id  TEXT
    )
  $sql$, p_schema, p_schema, p_schema);

  -- wls_installed_products
  -- Tracks JRF, Coherence, SOA Suite, OSB, OAM, etc. installed in each domain
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.wls_installed_products (
      product_id        SERIAL PRIMARY KEY,
      domain_id         INTEGER NOT NULL
                          REFERENCES %I.wls_domains (domain_id) ON DELETE CASCADE,
      product_name      TEXT NOT NULL,   -- e.g. 'Oracle SOA Suite', 'Oracle Coherence'
      product_version   TEXT,
      home_path         TEXT,
      discovery_run_id  TEXT,
      recorded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  $sql$, p_schema, p_schema);

  -- Create indexes
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_proc_server   ON %I.oracle_processors (server_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_inst_server   ON %I.oracle_instances  (server_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_opt_inst      ON %I.oracle_options    (instance_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_wls_server    ON %I.wls_domains       (server_id)', p_schema, p_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_wls_ms_domain ON %I.wls_managed_servers (domain_id)', p_schema, p_schema);

  -- Install the per-client license_position view
  PERFORM sam_admin.install_license_position_view(p_schema);

  -- Install the upsert functions
  PERFORM sam_admin.install_upsert_functions(p_schema);

END;
$$;

-- Placeholder stubs (defined in 02_shared_schema.sql after shared schema exists)
-- These are called by install_client_tables above; they are replaced properly
-- once the shared schema is created. Order of execution:
--   01_admin_schema.sql → 02_shared_schema.sql → 03_client_template_functions.sql
CREATE OR REPLACE FUNCTION sam_admin.install_license_position_view(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  -- Implemented in 03_client_template_functions.sql
  NULL;
END;
$$;

CREATE OR REPLACE FUNCTION sam_admin.install_upsert_functions(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  -- Implemented in 03_client_template_functions.sql
  NULL;
END;
$$;

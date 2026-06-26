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

  -- Register client (skip silently if already exists)
  INSERT INTO sam_admin.clients (client_code, client_name, schema_name, contact_email)
  VALUES (p_code, p_name, v_schema, p_contact_email)
  ON CONFLICT (client_code) DO UPDATE
    SET client_name    = EXCLUDED.client_name,
        contact_email  = COALESCE(EXCLUDED.contact_email, sam_admin.clients.contact_email)
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
  BEGIN
    EXECUTE format(
      'CREATE TYPE %I.environment_type AS ENUM
       (''production'',''non_production'',''development'',''test'',''dr'',''unknown'')',
      p_schema
    );
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    EXECUTE format(
      'CREATE TYPE %I.virt_type AS ENUM
       (''physical'',''vmware'',''hyperv'',''kvm'',''xen'',''lpar'',''zone'',''container'',''unknown'')',
      p_schema
    );
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;

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
      is_active                BOOLEAN NOT NULL DEFAULT TRUE,
      first_seen               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_seen                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_discovery_run       TEXT,
      notes                    TEXT,
      licence_metric_override  TEXT
        CHECK (licence_metric_override IN ('processor_perpetual','named_user_plus'))
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

  -- discovery_changelog
  -- Populated automatically by triggers on oracle_options, oracle_instances,
  -- oracle_processors, wls_domains, and wls_installed_products.
  -- Records every new item and every licence-relevant change detected
  -- between discovery runs, with the previous and new values side by side.
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.discovery_changelog (
      change_id         SERIAL PRIMARY KEY,
      detected_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      discovery_run_id  TEXT,               -- run that first detected this change
      server_id         INTEGER
                          REFERENCES %I.oracle_servers (server_id) ON DELETE SET NULL,
      hostname          TEXT,               -- denormalised for readability after server delete
      change_category   TEXT NOT NULL,      -- 'oracle_option', 'oracle_instance',
                                            -- 'processor', 'wls_domain', 'wls_product'
      change_type       TEXT NOT NULL,      -- 'NEW', 'CHANGED', 'REMOVED'
      severity          TEXT NOT NULL       -- 'HIGH', 'MEDIUM', 'INFO'
                          DEFAULT 'MEDIUM', -- HIGH = licence-impacting
      object_name       TEXT NOT NULL,      -- e.g. option name, instance SID, domain name
      field_changed     TEXT,               -- which column changed (for CHANGED rows)
      old_value         TEXT,               -- previous value
      new_value         TEXT,               -- new value
      licence_impact    TEXT,               -- human-readable licence implication
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
  -- Explicit assignment of one or more CSI contracts to a server.
  -- A server can be covered by multiple CSIs (e.g. EE base from one CSI,
  -- Diagnostic Pack from a second CSI purchased separately).
  -- product_family scopes the assignment: one CSI covers the DB licence,
  -- another covers WLS on the same physical host.
  -- licences_consumed records how many licence units from the CSI this
  -- server uses — if NULL the position view calculates it automatically.
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.server_csi_map (
      map_id              SERIAL PRIMARY KEY,
      server_id           INTEGER NOT NULL
                            REFERENCES %I.oracle_servers (server_id) ON DELETE CASCADE,
      csi_id              INTEGER NOT NULL
                            REFERENCES shared.csi_contracts (csi_id),
      line_id             INTEGER
                            REFERENCES shared.license_entitlement_lines (line_id),
                            -- NULL = assignment covers all lines on the CSI.
                            -- Set to a specific line_id to assign at product level
                            -- (e.g. this server uses the Diagnostic Pack line only).
      product_family      TEXT NOT NULL,
                            -- 'oracle_database' or 'oracle_weblogic' — which
                            -- product on this server does this CSI assignment cover.
      licences_consumed   NUMERIC(10,2),
                            -- How many licence units this server draws from the CSI.
                            -- NULL = calculated automatically from processor topology.
      effective_date      DATE NOT NULL DEFAULT CURRENT_DATE,
      notes               TEXT,
      assigned_by         TEXT,          -- username or system that created the mapping
      created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE (server_id, csi_id, line_id, product_family)
    )
  $sql$, p_schema, p_schema);

  -- oracle_rac_nodes: Real Application Clusters node topology per DB instance
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

  -- oracle_pdbs: CDB/PDB topology (Oracle 12c+)
  -- Multitenant requires a separate licence when > 1 PDB is used per CDB.
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

  -- oracle_nup_users: Named User Plus user count snapshots per instance
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

  -- java_installations: Oracle JDK / GraalVM EE discovered on each server
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
                             'oracle_fusion_middleware', 'oracle_forms_reports',
                             'custom'
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

  -- mysql_installations: MySQL Enterprise / Community installs
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

  -- oci_instances: OCI compute instances discovered via OCI CLI
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

  -- Create indexes
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

  -- Install views and functions
  PERFORM sam_admin.install_license_position_view(p_schema);
  PERFORM sam_admin.install_license_options_view(p_schema);
  PERFORM sam_admin.install_server_coverage_view(p_schema);
  PERFORM sam_admin.install_changelog_objects(p_schema);
  PERFORM sam_admin.install_upsert_functions(p_schema);
  PERFORM sam_admin.install_extended_views(p_schema);

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

CREATE OR REPLACE FUNCTION sam_admin.install_license_options_view(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  -- Implemented in 03_client_template_functions.sql
  NULL;
END;
$$;

CREATE OR REPLACE FUNCTION sam_admin.install_server_coverage_view(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  -- Implemented in 03_client_template_functions.sql
  NULL;
END;
$$;

CREATE OR REPLACE FUNCTION sam_admin.install_changelog_objects(p_schema TEXT)
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

CREATE OR REPLACE FUNCTION sam_admin.install_extended_views(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  -- Implemented in 03_client_template_functions.sql
  NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- VMWARE CLUSTER INFRASTRUCTURE
-- Tracks vSphere clusters so Oracle licence footprint can be calculated
-- across all physical hosts in a cluster (Oracle does not accept VMware as
-- hard partitioning — the entire cluster must be licensed if any VM runs Oracle).
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
  guest_hostname          TEXT,    -- matches oracle_servers.hostname when populated
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

CREATE INDEX IF NOT EXISTS idx_vmw_cluster_client  ON sam_admin.vmware_clusters (client_id);
CREATE INDEX IF NOT EXISTS idx_vmw_host_cluster    ON sam_admin.vmware_hosts    (cluster_id);
CREATE INDEX IF NOT EXISTS idx_vmw_vm_cluster      ON sam_admin.vmware_vms      (cluster_id);
CREATE INDEX IF NOT EXISTS idx_vmw_vm_host         ON sam_admin.vmware_vms      (host_id);
CREATE INDEX IF NOT EXISTS idx_vmw_vm_hostname     ON sam_admin.vmware_vms      (guest_hostname);

-- View: clusters that contain at least one Oracle VM —
-- shows total physical core count that Oracle would require to be licensed.
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
-- Stores email / Slack / Teams webhook destinations for compliance alerts.
-- Dispatch is triggered by calling GET /api/dispatch-alerts from cron.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.alert_channels (
  channel_id    SERIAL PRIMARY KEY,
  channel_type  TEXT NOT NULL CHECK (channel_type IN ('email', 'slack', 'teams')),
  channel_name  TEXT NOT NULL,
  config        JSONB NOT NULL DEFAULT '{}',
  -- email config keys: smtp_host, smtp_port, smtp_user, smtp_password,
  --                    from_addr, to_addrs (array)
  -- slack config keys: webhook_url
  -- teams config keys: webhook_url
  enabled       BOOLEAN NOT NULL DEFAULT TRUE,
  min_severity  TEXT NOT NULL DEFAULT 'MEDIUM'
                  CHECK (min_severity IN ('LOW', 'MEDIUM', 'HIGH')),
  last_sent_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


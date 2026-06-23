-- =============================================================================
-- Migration 02: VMware clusters, SE2 violations, CPU validation, alert channels
-- Run once against an existing database after upgrading the code:
--   psql oracle_sam -f database/migrations/02_vmware_se2_cpu_alerts.sql
-- Safe to re-run — all statements use IF NOT EXISTS guards.
-- =============================================================================

-- Create VMware infrastructure tables in sam_admin
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
  vm_id              SERIAL PRIMARY KEY,
  cluster_id         INTEGER NOT NULL
                       REFERENCES sam_admin.vmware_clusters (cluster_id) ON DELETE CASCADE,
  host_id            INTEGER
                       REFERENCES sam_admin.vmware_hosts (host_id) ON DELETE SET NULL,
  vm_name            TEXT NOT NULL,
  vm_uuid            TEXT UNIQUE,
  guest_hostname     TEXT,
  guest_ip           TEXT,
  power_state        TEXT,
  vcpu_count         INTEGER,
  memory_mb          INTEGER,
  has_oracle_db      BOOLEAN NOT NULL DEFAULT FALSE,
  has_oracle_wls     BOOLEAN NOT NULL DEFAULT FALSE,
  has_oracle_java    BOOLEAN NOT NULL DEFAULT FALSE,
  discovery_run_id   TEXT,
  last_seen          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (cluster_id, vm_name)
);

CREATE INDEX IF NOT EXISTS idx_vmw_cluster_client  ON sam_admin.vmware_clusters (client_id);
CREATE INDEX IF NOT EXISTS idx_vmw_host_cluster    ON sam_admin.vmware_hosts    (cluster_id);
CREATE INDEX IF NOT EXISTS idx_vmw_vm_cluster      ON sam_admin.vmware_vms      (cluster_id);
CREATE INDEX IF NOT EXISTS idx_vmw_vm_host         ON sam_admin.vmware_vms      (host_id);
CREATE INDEX IF NOT EXISTS idx_vmw_vm_hostname     ON sam_admin.vmware_vms      (guest_hostname);

-- Alert channels table
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

-- Rebuild the VMware exposure view (idempotent)
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

-- Rebuild per-client schema views and add the new cpu_core_factor_lookup function
DO $$
DECLARE
  v_schema TEXT;
BEGIN
  -- Install the new shared helper function first
  PERFORM shared.cpu_core_factor_lookup('Intel Xeon');   -- smoke test

  -- Rebuild views in all active client schemas
  FOR v_schema IN
    SELECT schema_name FROM sam_admin.clients WHERE is_active
  LOOP
    RAISE NOTICE 'Migrating schema: %', v_schema;
    PERFORM sam_admin.install_extended_views(v_schema);
    RAISE NOTICE '  ✓ %', v_schema;
  END LOOP;
END;
$$;

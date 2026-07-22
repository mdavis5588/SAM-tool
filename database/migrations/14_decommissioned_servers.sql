-- Migration 14: Decommissioned servers archive
-- Records a snapshot of licence assignments at the point of decommission
-- so the history is preserved after the server is removed from inventory.

CREATE TABLE IF NOT EXISTS sam_admin.decommissioned_servers (
    decommission_id   SERIAL PRIMARY KEY,
    client_schema     TEXT        NOT NULL,
    client_name       TEXT        NOT NULL,
    server_id         INTEGER     NOT NULL,   -- original server_id (may be reused if re-registered)
    hostname          TEXT        NOT NULL,
    fqdn              TEXT,
    ip_address        TEXT,
    environment       TEXT,
    datacenter        TEXT,
    os_family         TEXT,
    first_seen        TIMESTAMPTZ,
    last_seen         TIMESTAMPTZ,
    licence_snapshot  JSONB       NOT NULL DEFAULT '[]',  -- array of licence assignment rows
    decommissioned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    decommissioned_by TEXT        NOT NULL,
    notes             TEXT
);

CREATE INDEX IF NOT EXISTS idx_decomm_schema
    ON sam_admin.decommissioned_servers (client_schema, decommissioned_at DESC);
CREATE INDEX IF NOT EXISTS idx_decomm_hostname
    ON sam_admin.decommissioned_servers (hostname);

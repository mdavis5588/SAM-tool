-- Migration 13: Stale server investigations
-- Tracks who is assigned to investigate servers not seen in 14+ days.

CREATE TABLE IF NOT EXISTS sam_admin.stale_server_investigations (
    investigation_id  SERIAL PRIMARY KEY,
    client_schema     TEXT    NOT NULL,
    server_id         INTEGER NOT NULL,
    hostname          TEXT    NOT NULL,
    assigned_to       TEXT,                          -- username from app_users
    status            TEXT    NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open','in_progress','resolved','dismissed')),
    notes             TEXT,
    opened_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    opened_by         TEXT        NOT NULL,
    resolved_at       TIMESTAMPTZ,
    resolved_by       TEXT,
    UNIQUE (client_schema, server_id)               -- one active investigation per server
);

CREATE INDEX IF NOT EXISTS idx_stale_inv_status
    ON sam_admin.stale_server_investigations (status, opened_at DESC);
CREATE INDEX IF NOT EXISTS idx_stale_inv_schema
    ON sam_admin.stale_server_investigations (client_schema);

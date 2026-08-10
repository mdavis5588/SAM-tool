-- Migration 08: Licence assignment approval queue
-- Proposers (client, dba) submit requests; approvers (contracting, superadmin) review.
-- Approved requests are applied to server_csi_map; all state changes logged to audit_log.

CREATE TABLE IF NOT EXISTS sam_admin.assignment_requests (
    request_id        SERIAL PRIMARY KEY,

    -- Which client / schema this request targets
    client_id         INTEGER NOT NULL REFERENCES sam_admin.clients(client_id) ON DELETE CASCADE,
    client_schema     TEXT    NOT NULL,

    -- Denormalised server info (schema is per-client so we store hostname too)
    server_id         INTEGER NOT NULL,
    hostname          TEXT    NOT NULL,
    environment       TEXT,

    -- What licence is being proposed
    csi_id            INTEGER NOT NULL,
    csi_number        TEXT    NOT NULL,
    product_family    TEXT    NOT NULL,
    product_detail    TEXT,                   -- NULL = base line
    licences_consumed NUMERIC(10,2),          -- NULL = auto-calculate
    notes             TEXT,

    -- Proposal metadata
    proposed_by       TEXT    NOT NULL,
    proposed_by_role  TEXT    NOT NULL,
    proposed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Request type: 'assign' or 'remove'
    request_type      TEXT    NOT NULL DEFAULT 'assign'
                      CHECK (request_type IN ('assign','remove')),
    -- For remove requests, the map_id to delete
    map_id_to_remove  INTEGER,

    -- Review
    status            TEXT    NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','approved','rejected','withdrawn')),
    reviewed_by       TEXT,
    reviewed_at       TIMESTAMPTZ,
    review_note       TEXT,

    -- When the approved change was actually applied to server_csi_map
    applied_at        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_asgn_req_status
    ON sam_admin.assignment_requests (status, proposed_at DESC);

CREATE INDEX IF NOT EXISTS idx_asgn_req_client
    ON sam_admin.assignment_requests (client_id, status);

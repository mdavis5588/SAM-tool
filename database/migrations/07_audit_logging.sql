-- Migration 07: Audit logging
-- Creates licence position snapshots (24-month retention) and user activity
-- audit log (6-month retention). Both tables are in sam_admin schema.

-- -------------------------------------------------------------------------
-- Licence position snapshots
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.licence_snapshots (
  snapshot_id    SERIAL PRIMARY KEY,
  client_id      INTEGER NOT NULL REFERENCES sam_admin.clients(client_id) ON DELETE CASCADE,
  snapshot_month DATE    NOT NULL,   -- always stored as first day of the month
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

-- -------------------------------------------------------------------------
-- User activity audit log
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sam_admin.audit_log (
  audit_id      BIGSERIAL PRIMARY KEY,
  username      TEXT NOT NULL,
  user_role     TEXT,
  action        TEXT NOT NULL,   -- e.g. 'server.set_metric', 'csi.assign', 'user.create'
  entity_type   TEXT,            -- 'server', 'contract', 'user', 'csi_assignment'
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

-- -------------------------------------------------------------------------
-- Automatic retention enforcement (run via a scheduled call or on insert)
-- Call sam_admin.purge_old_audit_data() from a cron endpoint or daily job.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.purge_old_audit_data()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  v_snap_deleted  INTEGER;
  v_audit_deleted INTEGER;
BEGIN
  -- Remove licence snapshots older than 24 months
  DELETE FROM sam_admin.licence_snapshots
  WHERE taken_at < NOW() - INTERVAL '24 months';
  GET DIAGNOSTICS v_snap_deleted = ROW_COUNT;

  -- Remove audit log entries older than 6 months
  DELETE FROM sam_admin.audit_log
  WHERE created_at < NOW() - INTERVAL '6 months';
  GET DIAGNOSTICS v_audit_deleted = ROW_COUNT;

  RETURN FORMAT('Purged %s snapshot(s) and %s audit log row(s)', v_snap_deleted, v_audit_deleted);
END; $$;

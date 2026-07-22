-- Migration 12: FinOps shared pool monthly cost snapshots
-- Records point-in-time shared pool licence usage and cost per client per CSI per month.

CREATE TABLE IF NOT EXISTS sam_admin.finops_pool_snapshots (
  snapshot_id    SERIAL PRIMARY KEY,
  snapshot_month DATE        NOT NULL,   -- first day of month
  taken_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  taken_by       TEXT        NOT NULL
);

-- One row per client × CSI combination
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

CREATE UNIQUE INDEX IF NOT EXISTS idx_finops_pool_snap_month
  ON sam_admin.finops_pool_snapshots (snapshot_month);

CREATE INDEX IF NOT EXISTS idx_finops_pool_snap_lines
  ON sam_admin.finops_pool_snapshot_lines (snapshot_id);

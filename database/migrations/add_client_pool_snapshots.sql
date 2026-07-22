-- Per-client monthly shared pool snapshots
CREATE TABLE IF NOT EXISTS sam_admin.client_pool_snapshots (
  snapshot_id    SERIAL PRIMARY KEY,
  client_id      INTEGER NOT NULL REFERENCES sam_admin.clients(client_id) ON DELETE CASCADE,
  snapshot_month DATE        NOT NULL,
  taken_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  taken_by       TEXT        NOT NULL,
  note           TEXT,
  UNIQUE (client_id, snapshot_month)
);

CREATE INDEX IF NOT EXISTS idx_client_pool_snap_client
  ON sam_admin.client_pool_snapshots (client_id);

CREATE TABLE IF NOT EXISTS sam_admin.client_pool_snapshot_lines (
  line_id        SERIAL PRIMARY KEY,
  snapshot_id    INTEGER NOT NULL
                   REFERENCES sam_admin.client_pool_snapshots(snapshot_id) ON DELETE CASCADE,
  csi_number     TEXT    NOT NULL,
  contract_name  TEXT,
  product_name   TEXT,
  licences_used  NUMERIC NOT NULL DEFAULT 0,
  unit_price     NUMERIC NOT NULL DEFAULT 0,
  monthly_cost   NUMERIC NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_client_pool_snap_lines
  ON sam_admin.client_pool_snapshot_lines (snapshot_id);

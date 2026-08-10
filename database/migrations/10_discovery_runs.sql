-- Migration 10: Discovery run history log
--
-- Records every call to register_server() as a discovery run event so
-- administrators can see when each source last ran, how many servers it
-- touched, and whether any conflicts or errors occurred.
--
-- Also adds a sam_admin.log_discovery_run() helper that Ansible and cron
-- scripts call once per discovery sweep (not per server).

DROP TABLE IF EXISTS sam_admin.discovery_runs CASCADE;

CREATE TABLE sam_admin.discovery_runs (
    run_id           SERIAL PRIMARY KEY,
    client_id        INTEGER NOT NULL REFERENCES sam_admin.clients(client_id) ON DELETE CASCADE,
    client_schema    TEXT    NOT NULL,
    discovery_source TEXT    NOT NULL,          -- 'ansible' | 'psql_cron' | 'manual' | ...
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


-- ── log_discovery_run() ──────────────────────────────────────────────────────
-- Call once at the END of each discovery sweep with the totals.
-- Returns the run_id so callers can link individual server results back to it.

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
RETURNS INTEGER
LANGUAGE plpgsql AS $$
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
END;
$$;

COMMENT ON FUNCTION sam_admin.log_discovery_run IS
'Record the results of one discovery sweep. Call once per run with totals.
Returns the new run_id. Example:
  SELECT sam_admin.log_discovery_run(
    p_schema           => ''client_acme'',
    p_source           => ''ansible'',
    p_servers_seen     => 42,
    p_servers_new      => 2,
    p_servers_updated  => 40,
    p_servers_conflict => 0,
    p_run_host         => ''ansible-ctrl01'',
    p_status           => ''completed''
  );';

COMMENT ON TABLE sam_admin.discovery_runs IS
'One row per discovery sweep. Populated by Ansible playbooks and PSQL cron
scripts calling sam_admin.log_discovery_run(), and by the manual registration
UI in Helios.';

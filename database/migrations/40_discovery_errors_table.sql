-- Migration 40: Add discovery_errors table to each client schema.
--              Records connection/query failures from Ansible discovery runs
--              so they are visible in the admin UI without digging through logs.

CREATE OR REPLACE FUNCTION sam_admin._add_discovery_errors_table(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($sql$
    CREATE TABLE IF NOT EXISTS %I.discovery_errors (
      error_id        SERIAL PRIMARY KEY,
      run_id          TEXT        NOT NULL,
      hostname        TEXT        NOT NULL,
      oracle_sid      TEXT,
      error_type      TEXT        NOT NULL,  -- e.g. 'connection_failed', 'query_failed'
      error_detail    TEXT,
      recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS idx_discovery_errors_hostname
      ON %I.discovery_errors (hostname, recorded_at DESC);
    CREATE INDEX IF NOT EXISTS idx_discovery_errors_run_id
      ON %I.discovery_errors (run_id);
  $sql$, p_schema, p_schema, p_schema);
END;
$$;

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin._add_discovery_errors_table(v_client.schema_name);
    RAISE NOTICE 'Added discovery_errors to %', v_client.schema_name;
  END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS sam_admin._add_discovery_errors_table(TEXT);

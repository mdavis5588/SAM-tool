-- =============================================================================
-- Migration 21: PDB-level feature usage
--
-- Extends oracle_feature_usage to store feature data at the PDB level.
-- A NULL pdb_name means the row is CDB/instance-level (from
-- DBA_FEATURE_USAGE_STATISTICS).  A non-NULL pdb_name is a per-PDB row
-- sourced from CDB_FEATURE_USAGE_STATISTICS for that container.
--
-- Changes:
--   1. Add pdb_name column to oracle_feature_usage
--   2. Replace the (instance_id, feature_name) unique constraint with
--      (instance_id, COALESCE(pdb_name,''), feature_name) via a unique index
--   3. Extend install_feature_usage_upsert to persist per-PDB features
--      from the pdb[].feature_usage arrays in the discovery payload
--
-- Apply:
--   psql $DSN -f database/migrations/21_pdb_feature_usage.sql
-- =============================================================================

-- 1. Add pdb_name column to every existing client oracle_feature_usage table
CREATE OR REPLACE FUNCTION sam_admin.migrate_pdb_feature_usage_column(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  -- Add pdb_name column (idempotent)
  EXECUTE format(
    'ALTER TABLE %I.oracle_feature_usage ADD COLUMN IF NOT EXISTS pdb_name TEXT',
    p_schema
  );

  -- Drop the old unique constraint/index on (instance_id, feature_name)
  -- and replace with one that includes pdb_name (NULLs treated as empty string)
  EXECUTE format(
    $idx$
    DO $do$
    BEGIN
      -- Drop old unique constraint if it exists
      BEGIN
        ALTER TABLE %I.oracle_feature_usage
          DROP CONSTRAINT IF EXISTS oracle_feature_usage_instance_id_feature_name_key;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END $do$;
    $idx$,
    p_schema
  );

  -- Create new unique index covering pdb_name (COALESCE so NULLs compare equal)
  EXECUTE format(
    $idx$
    CREATE UNIQUE INDEX IF NOT EXISTS idx_%s_feat_usage_uniq
      ON %I.oracle_feature_usage (instance_id, COALESCE(pdb_name, ''), feature_name)
    $idx$,
    p_schema, p_schema
  );
END;
$$;

DO $$
DECLARE v_schema TEXT;
BEGIN
  FOR v_schema IN SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name
  LOOP
    PERFORM sam_admin.migrate_pdb_feature_usage_column(v_schema);
  END LOOP;
END;
$$;


-- 2. Extend install_feature_usage_table so new clients get pdb_name from the start
CREATE OR REPLACE FUNCTION sam_admin.install_feature_usage_table(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($ddl$
    CREATE TABLE IF NOT EXISTS %I.oracle_feature_usage (
      feature_id        SERIAL PRIMARY KEY,
      instance_id       INTEGER NOT NULL
                          REFERENCES %I.oracle_instances(instance_id) ON DELETE CASCADE,
      pdb_name          TEXT,
      feature_name      TEXT    NOT NULL,
      db_version        TEXT,
      detected_usages   INTEGER NOT NULL DEFAULT 0,
      total_samples     INTEGER NOT NULL DEFAULT 0,
      currently_used    BOOLEAN NOT NULL DEFAULT FALSE,
      first_usage_date  DATE,
      last_usage_date   DATE,
      last_sample_date  DATE,
      discovery_run_id  TEXT
    )
  $ddl$, p_schema, p_schema);

  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS idx_%s_feat_usage_inst ON %I.oracle_feature_usage (instance_id)',
    p_schema, p_schema
  );
  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS idx_%s_feat_usage_last ON %I.oracle_feature_usage (last_usage_date)',
    p_schema, p_schema
  );
  EXECUTE format(
    $idx$
    CREATE UNIQUE INDEX IF NOT EXISTS idx_%s_feat_usage_uniq
      ON %I.oracle_feature_usage (instance_id, COALESCE(pdb_name, ''), feature_name)
    $idx$,
    p_schema, p_schema
  );
END;
$$;


-- 3. Extend upsert to persist per-PDB feature_usage from pdb[].feature_usage arrays
CREATE OR REPLACE FUNCTION sam_admin.install_feature_usage_upsert(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.upsert_oracle_feature_usage(p_payload JSONB)
    RETURNS VOID LANGUAGE plpgsql AS $body$
    DECLARE
      v_inst        JSONB;
      v_pdb         JSONB;
      v_feat        JSONB;
      v_instance_id INTEGER;
      v_run_id      TEXT := p_payload->>'run_id';
    BEGIN
      FOR v_inst IN SELECT * FROM jsonb_array_elements(COALESCE(p_payload->'instances', '[]'::jsonb))
      LOOP
        -- Look up the instance_id for this SID
        SELECT instance_id INTO v_instance_id
        FROM   %I.oracle_instances
        WHERE  oracle_sid = v_inst->>'sid'
        LIMIT  1;

        IF v_instance_id IS NULL THEN CONTINUE; END IF;

        -- CDB/instance-level features (pdb_name = NULL)
        FOR v_feat IN SELECT * FROM jsonb_array_elements(COALESCE(v_inst->'feature_usage', '[]'::jsonb))
        LOOP
          INSERT INTO %I.oracle_feature_usage
            (instance_id, pdb_name, feature_name, db_version,
             detected_usages, total_samples, currently_used,
             first_usage_date, last_usage_date, last_sample_date, discovery_run_id)
          VALUES (
            v_instance_id,
            NULL,
            v_feat->>'feature_name',
            v_feat->>'db_version',
            COALESCE((v_feat->>'detected_usages')::INTEGER, 0),
            COALESCE((v_feat->>'total_samples')::INTEGER,   0),
            COALESCE((v_feat->>'currently_used')::BOOLEAN,  FALSE),
            CASE WHEN v_feat->>'first_usage_date' IS NOT NULL
                 THEN (v_feat->>'first_usage_date')::DATE END,
            CASE WHEN v_feat->>'last_usage_date'  IS NOT NULL
                 THEN (v_feat->>'last_usage_date')::DATE  END,
            CURRENT_DATE,
            v_run_id
          )
          ON CONFLICT (instance_id, COALESCE(pdb_name, ''), feature_name) DO UPDATE SET
            db_version       = EXCLUDED.db_version,
            detected_usages  = EXCLUDED.detected_usages,
            total_samples    = EXCLUDED.total_samples,
            currently_used   = EXCLUDED.currently_used,
            first_usage_date = COALESCE(EXCLUDED.first_usage_date,
                                        %I.oracle_feature_usage.first_usage_date),
            last_usage_date  = CASE
              WHEN EXCLUDED.last_usage_date IS NOT NULL
               AND EXCLUDED.last_usage_date > COALESCE(%I.oracle_feature_usage.last_usage_date, '1900-01-01'::DATE)
              THEN EXCLUDED.last_usage_date
              ELSE %I.oracle_feature_usage.last_usage_date
            END,
            last_sample_date = CURRENT_DATE,
            discovery_run_id = EXCLUDED.discovery_run_id;
        END LOOP;

        -- Per-PDB features (pdb_name populated)
        FOR v_pdb IN SELECT * FROM jsonb_array_elements(COALESCE(v_inst->'pdbs', '[]'::jsonb))
        LOOP
          FOR v_feat IN SELECT * FROM jsonb_array_elements(COALESCE(v_pdb->'feature_usage', '[]'::jsonb))
          LOOP
            INSERT INTO %I.oracle_feature_usage
              (instance_id, pdb_name, feature_name, db_version,
               detected_usages, total_samples, currently_used,
               first_usage_date, last_usage_date, last_sample_date, discovery_run_id)
            VALUES (
              v_instance_id,
              v_pdb->>'pdb_name',
              v_feat->>'feature_name',
              v_feat->>'db_version',
              COALESCE((v_feat->>'detected_usages')::INTEGER, 0),
              COALESCE((v_feat->>'total_samples')::INTEGER,   0),
              COALESCE((v_feat->>'currently_used')::BOOLEAN,  FALSE),
              CASE WHEN v_feat->>'first_usage_date' IS NOT NULL
                   THEN (v_feat->>'first_usage_date')::DATE END,
              CASE WHEN v_feat->>'last_usage_date'  IS NOT NULL
                   THEN (v_feat->>'last_usage_date')::DATE  END,
              CURRENT_DATE,
              v_run_id
            )
            ON CONFLICT (instance_id, COALESCE(pdb_name, ''), feature_name) DO UPDATE SET
              db_version       = EXCLUDED.db_version,
              detected_usages  = EXCLUDED.detected_usages,
              total_samples    = EXCLUDED.total_samples,
              currently_used   = EXCLUDED.currently_used,
              first_usage_date = COALESCE(EXCLUDED.first_usage_date,
                                          %I.oracle_feature_usage.first_usage_date),
              last_usage_date  = CASE
                WHEN EXCLUDED.last_usage_date IS NOT NULL
                 AND EXCLUDED.last_usage_date > COALESCE(%I.oracle_feature_usage.last_usage_date, '1900-01-01'::DATE)
                THEN EXCLUDED.last_usage_date
                ELSE %I.oracle_feature_usage.last_usage_date
              END,
              last_sample_date = CURRENT_DATE,
              discovery_run_id = EXCLUDED.discovery_run_id;
          END LOOP;
        END LOOP;

      END LOOP;
    END;
    $body$;
  $fn$,
  p_schema,
  p_schema, p_schema,
  p_schema, p_schema, p_schema,
  p_schema, p_schema, p_schema);
END;
$$;

-- Install updated upsert on all existing client schemas
DO $$
DECLARE v_schema TEXT;
BEGIN
  FOR v_schema IN SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_feature_usage_upsert(v_schema);
  END LOOP;
END;
$$;

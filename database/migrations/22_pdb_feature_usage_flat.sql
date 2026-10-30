-- =============================================================================
-- Migration 22: Extend upsert_oracle_feature_usage to handle flat
--               pdb_feature_usage array at instance level
--
-- The Ansible playbooks emit per-PDB feature rows as a flat array with
-- a pdb_name field at the instance level (instance.pdb_feature_usage[])
-- rather than embedding them inside each pdb object.  This is simpler to
-- build in Ansible Jinja2 and avoids the need for per-PDB Jinja2 grouping.
--
-- The DB function now processes both paths:
--   1. instance.feature_usage[]          → pdb_name = NULL  (CDB-level)
--   2. instance.pdb_feature_usage[]      → pdb_name from row (PDB-level, flat)
--   3. instance.pdbs[].feature_usage[]   → pdb_name from parent pdb object
--
-- Apply:
--   psql $DSN -f database/migrations/22_pdb_feature_usage_flat.sql
-- =============================================================================

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
        SELECT instance_id INTO v_instance_id
        FROM   %I.oracle_instances
        WHERE  oracle_sid = v_inst->>'sid'
        LIMIT  1;

        IF v_instance_id IS NULL THEN CONTINUE; END IF;

        -- 1. CDB/instance-level features (pdb_name = NULL)
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

        -- 2. Flat PDB feature rows (pdb_name comes from each row)
        FOR v_feat IN SELECT * FROM jsonb_array_elements(COALESCE(v_inst->'pdb_feature_usage', '[]'::jsonb))
        LOOP
          CONTINUE WHEN v_feat->>'pdb_name' IS NULL OR v_feat->>'feature_name' IS NULL;
          INSERT INTO %I.oracle_feature_usage
            (instance_id, pdb_name, feature_name, db_version,
             detected_usages, total_samples, currently_used,
             first_usage_date, last_usage_date, last_sample_date, discovery_run_id)
          VALUES (
            v_instance_id,
            v_feat->>'pdb_name',
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

        -- 3. Per-PDB features nested inside pdbs[] objects
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
  p_schema,                               -- 1:  function schema
  p_schema, p_schema,                     -- 2:  oracle_instances  3: oracle_feature_usage (INSERT CDB)
  p_schema, p_schema, p_schema,           -- 4-6: first/last/last_usage_date (DO UPDATE CDB)
  p_schema,                               -- 7:  oracle_feature_usage (INSERT flat PDB)
  p_schema, p_schema, p_schema,           -- 8-10: first/last/last_usage_date (DO UPDATE flat PDB)
  p_schema,                               -- 11: oracle_feature_usage (INSERT nested PDB)
  p_schema, p_schema, p_schema);          -- 12-14: first/last/last_usage_date (DO UPDATE nested PDB)
END;
$$;

-- Re-install updated upsert on all existing client schemas
DO $$
DECLARE v_schema TEXT;
BEGIN
  FOR v_schema IN SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_feature_usage_upsert(v_schema);
  END LOOP;
END;
$$;

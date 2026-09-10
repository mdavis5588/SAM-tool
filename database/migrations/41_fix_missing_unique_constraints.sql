-- Migration 41: Add missing unique constraint on oracle_rac_nodes and fix
--              upsert_oracle_extended_discovery ON CONFLICT clauses to match
--              actual indexes.
--
-- Problems fixed:
--   1. oracle_rac_nodes missing UNIQUE(instance_id, node_name) constraint
--   2. oracle_feature_usage ON CONFLICT used (instance_id, feature_name) but
--      the actual unique index is (instance_id, COALESCE(pdb_name,''), feature_name)

-- 1. Add missing unique constraint to oracle_rac_nodes in all client schemas
CREATE OR REPLACE FUNCTION sam_admin._fix_rac_nodes_constraint(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format(
    'ALTER TABLE %I.oracle_rac_nodes
     ADD CONSTRAINT oracle_rac_nodes_instance_id_node_name_key
     UNIQUE (instance_id, node_name)',
    p_schema
  );
EXCEPTION WHEN duplicate_table THEN NULL;
         WHEN others THEN
           -- constraint may already exist under a different name
           NULL;
END;
$$;

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin._fix_rac_nodes_constraint(v_client.schema_name);
    RAISE NOTICE 'Fixed oracle_rac_nodes constraint for %', v_client.schema_name;
  END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS sam_admin._fix_rac_nodes_constraint(TEXT);

-- 2. Patch upsert_oracle_extended_discovery to use correct ON CONFLICT clauses
CREATE OR REPLACE FUNCTION sam_admin._patch_extended_upsert(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.upsert_oracle_extended_discovery(p_payload JSONB)
    RETURNS VOID LANGUAGE plpgsql AS $body$
    DECLARE
      v_hostname   TEXT;
      v_server_id  INTEGER;
      v_inst       JSONB;
      v_instance_id INTEGER;
      v_node       JSONB;
      v_pdb        JSONB;
      v_feat       JSONB;
      v_param      JSONB;
    BEGIN
      v_hostname := p_payload->>'hostname';

      SELECT server_id INTO v_server_id
      FROM   %I.oracle_servers
      WHERE  hostname = v_hostname;

      IF v_server_id IS NULL THEN RETURN; END IF;

      FOR v_inst IN SELECT * FROM jsonb_array_elements(p_payload->'instances')
      LOOP
        CONTINUE WHEN v_inst->>'sid' IS NULL OR TRIM(v_inst->>'sid') = '';

        SELECT instance_id INTO v_instance_id
        FROM   %I.oracle_instances
        WHERE  server_id = v_server_id
          AND  oracle_sid = v_inst->>'sid';

        CONTINUE WHEN v_instance_id IS NULL;

        -- Update NUP counts
        UPDATE %I.oracle_instances SET
          nup_total_users  = (v_inst->>'nup_total_users')::INTEGER,
          nup_active_users = (v_inst->>'nup_active_users')::INTEGER,
          nup_locked_users = (v_inst->>'nup_locked_users')::INTEGER,
          nup_sample_users = (v_inst->'nup_sample_users')::JSONB
        WHERE instance_id = v_instance_id;

        -- RAC nodes
        FOR v_node IN SELECT * FROM jsonb_array_elements(v_inst->'rac_nodes')
        LOOP
          CONTINUE WHEN v_node->>'node_name' IS NULL;
          INSERT INTO %I.oracle_rac_nodes
            (instance_id, server_id, node_name, node_number, instance_name,
             last_seen, discovery_run_id)
          VALUES (
            v_instance_id, v_server_id,
            v_node->>'node_name',
            (v_node->>'node_number')::INTEGER,
            v_node->>'instance_name',
            NOW(), p_payload->>'run_id'
          )
          ON CONFLICT (instance_id, node_name) DO UPDATE SET
            node_number      = EXCLUDED.node_number,
            instance_name    = EXCLUDED.instance_name,
            last_seen        = NOW(),
            discovery_run_id = EXCLUDED.discovery_run_id,
            is_active        = TRUE;
        END LOOP;

        -- PDBs
        FOR v_pdb IN SELECT * FROM jsonb_array_elements(v_inst->'pdbs')
        LOOP
          CONTINUE WHEN v_pdb->>'pdb_name' IS NULL;
          INSERT INTO %I.oracle_pdbs
            (instance_id, pdb_name, con_id, open_mode, restricted,
             nup_active_users, nup_total_users, mgmt_pack_access,
             diagnostics_licensed, tuning_licensed,
             last_seen, discovery_run_id)
          VALUES (
            v_instance_id,
            v_pdb->>'pdb_name',
            (v_pdb->>'con_id')::INTEGER,
            v_pdb->>'open_mode',
            v_pdb->>'restricted',
            (v_pdb->>'nup_active_users')::INTEGER,
            (v_pdb->>'nup_total_users')::INTEGER,
            v_pdb->>'mgmt_pack_access',
            (v_pdb->>'diagnostics_licensed')::BOOLEAN,
            (v_pdb->>'tuning_licensed')::BOOLEAN,
            NOW(), p_payload->>'run_id'
          )
          ON CONFLICT (instance_id, pdb_name) DO UPDATE SET
            con_id              = EXCLUDED.con_id,
            open_mode           = EXCLUDED.open_mode,
            restricted          = EXCLUDED.restricted,
            nup_active_users    = EXCLUDED.nup_active_users,
            nup_total_users     = EXCLUDED.nup_total_users,
            mgmt_pack_access    = EXCLUDED.mgmt_pack_access,
            diagnostics_licensed = EXCLUDED.diagnostics_licensed,
            tuning_licensed     = EXCLUDED.tuning_licensed,
            last_seen           = NOW(),
            discovery_run_id    = EXCLUDED.discovery_run_id;
        END LOOP;

        -- Feature usage — ON CONFLICT must match (instance_id, COALESCE(pdb_name,''), feature_name)
        FOR v_feat IN SELECT * FROM jsonb_array_elements(v_inst->'feature_usage')
        LOOP
          CONTINUE WHEN v_feat->>'feature_name' IS NULL;
          INSERT INTO %I.oracle_feature_usage
            (instance_id, feature_name, db_version, detected_usages,
             total_samples, currently_used, first_usage_date, last_usage_date,
             discovery_run_id)
          VALUES (
            v_instance_id,
            v_feat->>'feature_name',
            v_feat->>'db_version',
            (v_feat->>'detected_usages')::INTEGER,
            (v_feat->>'total_samples')::INTEGER,
            (v_feat->>'currently_used')::BOOLEAN,
            (v_feat->>'first_usage_date')::DATE,
            (v_feat->>'last_usage_date')::DATE,
            p_payload->>'run_id'
          )
          ON CONFLICT (instance_id, COALESCE(pdb_name, ''), feature_name) DO UPDATE SET
            db_version       = EXCLUDED.db_version,
            detected_usages  = EXCLUDED.detected_usages,
            total_samples    = EXCLUDED.total_samples,
            currently_used   = EXCLUDED.currently_used,
            first_usage_date = EXCLUDED.first_usage_date,
            last_usage_date  = EXCLUDED.last_usage_date,
            discovery_run_id = EXCLUDED.discovery_run_id;
        END LOOP;

      END LOOP;
    END;
    $body$;
  $fn$,
  p_schema,   -- 1: function schema
  p_schema,   -- 2: oracle_servers
  p_schema,   -- 3: oracle_instances (lookup)
  p_schema,   -- 4: oracle_instances (update NUP)
  p_schema,   -- 5: oracle_rac_nodes
  p_schema,   -- 6: oracle_pdbs
  p_schema);  -- 7: oracle_feature_usage
END;
$$;

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin._patch_extended_upsert(v_client.schema_name);
    RAISE NOTICE 'Patched upsert_oracle_extended_discovery for %', v_client.schema_name;
  END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS sam_admin._patch_extended_upsert(TEXT);

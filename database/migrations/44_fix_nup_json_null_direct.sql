-- Migration 44: Directly redeploy upsert_oracle_extended_discovery with NULLIF fix.
--
-- Migrations 42 and 43 used nested dollar-quoting inside format() which did
-- not update the live function. This migration builds the function SQL using
-- replace() on a template string so the live function is guaranteed to update.
-- Also adds NULLIF guards to rac_nodes, pdbs, and feature_usage FOR loops so
-- Oracle JSON null on any sub-array no longer causes "cannot extract elements
-- from a scalar".

DO $MIGR44$
DECLARE
  v_schema TEXT;
  v_sql    TEXT;
  v_tmpl   TEXT;
BEGIN
  v_tmpl := $TMPL$
CREATE OR REPLACE FUNCTION SCHEMA_NAME.upsert_oracle_extended_discovery(p_payload JSONB)
RETURNS VOID LANGUAGE plpgsql AS $_BODY_$
DECLARE
  v_hostname    TEXT;
  v_server_id   INTEGER;
  v_inst        JSONB;
  v_instance_id INTEGER;
  v_node        JSONB;
  v_pdb         JSONB;
  v_feat        JSONB;
BEGIN
  v_hostname := p_payload->>'hostname';

  SELECT server_id INTO v_server_id
  FROM   SCHEMA_NAME.oracle_servers
  WHERE  hostname = v_hostname;

  IF v_server_id IS NULL THEN RETURN; END IF;

  FOR v_inst IN SELECT * FROM jsonb_array_elements(p_payload->'instances')
  LOOP
    CONTINUE WHEN v_inst->>'sid' IS NULL OR TRIM(v_inst->>'sid') = '';

    SELECT instance_id INTO v_instance_id
    FROM   SCHEMA_NAME.oracle_instances
    WHERE  server_id = v_server_id
      AND  oracle_sid = v_inst->>'sid';

    CONTINUE WHEN v_instance_id IS NULL;

    INSERT INTO SCHEMA_NAME.oracle_nup_users
      (instance_id, snapshot_date, active_user_count, total_user_count,
       locked_user_count, sample_user_list, discovery_run_id)
    VALUES (
      v_instance_id,
      CURRENT_DATE,
      COALESCE((v_inst->>'nup_active_users')::INTEGER, 0),
      COALESCE((v_inst->>'nup_total_users')::INTEGER,  0),
      COALESCE((v_inst->>'nup_locked_users')::INTEGER, 0),
      ARRAY(SELECT jsonb_array_elements_text(
        COALESCE(NULLIF(v_inst->'nup_sample_users', 'null'::jsonb), '[]'::jsonb)
      )),
      p_payload->>'run_id'
    );

    FOR v_node IN SELECT * FROM jsonb_array_elements(
      COALESCE(NULLIF(v_inst->'rac_nodes', 'null'::jsonb), '[]'::jsonb))
    LOOP
      CONTINUE WHEN v_node->>'node_name' IS NULL;
      INSERT INTO SCHEMA_NAME.oracle_rac_nodes
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

    FOR v_pdb IN SELECT * FROM jsonb_array_elements(
      COALESCE(NULLIF(v_inst->'pdbs', 'null'::jsonb), '[]'::jsonb))
    LOOP
      CONTINUE WHEN v_pdb->>'pdb_name' IS NULL;
      INSERT INTO SCHEMA_NAME.oracle_pdbs
        (instance_id, pdb_name, pdb_con_id, open_mode, restricted,
         last_seen, discovery_run_id)
      VALUES (
        v_instance_id,
        v_pdb->>'pdb_name',
        (v_pdb->>'con_id')::INTEGER,
        v_pdb->>'open_mode',
        v_pdb->>'restricted',
        NOW(), p_payload->>'run_id'
      )
      ON CONFLICT (instance_id, pdb_name) DO UPDATE SET
        pdb_con_id       = EXCLUDED.pdb_con_id,
        open_mode        = EXCLUDED.open_mode,
        restricted       = EXCLUDED.restricted,
        last_seen        = NOW(),
        discovery_run_id = EXCLUDED.discovery_run_id;
    END LOOP;

    FOR v_feat IN SELECT * FROM jsonb_array_elements(
      COALESCE(NULLIF(v_inst->'feature_usage', 'null'::jsonb), '[]'::jsonb))
    LOOP
      CONTINUE WHEN v_feat->>'feature_name' IS NULL;
      INSERT INTO SCHEMA_NAME.oracle_feature_usage
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
$_BODY_$;
  $TMPL$;

  FOR v_schema IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    v_sql := replace(v_tmpl, 'SCHEMA_NAME', v_schema);
    EXECUTE v_sql;
    RAISE NOTICE 'Updated upsert_oracle_extended_discovery for schema: %', v_schema;
  END LOOP;
END;
$MIGR44$;

-- Migration 19: Persist DBA_FEATURE_USAGE_STATISTICS and add dormant-feature alert
--
-- Previously the feature_usage array in the extended discovery payload was
-- collected but discarded.  This migration:
--   1. Creates oracle_feature_usage per-client table (via install_client_tables)
--   2. Extends upsert_oracle_extended_discovery to persist the feature_usage rows
--   3. Adds a FEATURE_DORMANT alert to get_compliance_alerts() for features
--      present on a server but with last_usage_date > 6 months ago
--
-- Apply:
--   psql $DSN -f database/migrations/19_feature_usage_table_and_alert.sql
--   psql $DSN -f database/migrations/11_refresh_client_functions.sql


-- -------------------------------------------------------------------------
-- 1. Create oracle_feature_usage table in every existing client schema
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.install_feature_usage_table(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($ddl$
    CREATE TABLE IF NOT EXISTS %I.oracle_feature_usage (
      feature_id        SERIAL PRIMARY KEY,
      instance_id       INTEGER NOT NULL
                          REFERENCES %I.oracle_instances(instance_id) ON DELETE CASCADE,
      feature_name      TEXT    NOT NULL,
      db_version        TEXT,
      detected_usages   INTEGER NOT NULL DEFAULT 0,
      total_samples     INTEGER NOT NULL DEFAULT 0,
      currently_used    BOOLEAN NOT NULL DEFAULT FALSE,
      first_usage_date  DATE,
      last_usage_date   DATE,
      last_sample_date  DATE,   -- date this row was last refreshed by discovery
      discovery_run_id  TEXT,
      UNIQUE (instance_id, feature_name)
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
END;
$$;

-- Install on all existing client schemas
DO $$
DECLARE v_schema TEXT;
BEGIN
  FOR v_schema IN SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_feature_usage_table(v_schema);
  END LOOP;
END;
$$;


-- -------------------------------------------------------------------------
-- 2. Extend install_extended_views() so new clients get the table too
--    (hook via install_upsert_functions which is called by install_client_tables)
-- -------------------------------------------------------------------------
-- We patch install_changelog_objects to also call install_feature_usage_table.
-- Guard against running before this migration is applied.

-- Add the call at the end of install_changelog_objects (already has the
-- install_feature_activation_trigger hook from migration 17; append here).

-- Rather than reprint install_changelog_objects, we extend
-- install_client_tables via a post-install hook stored in a small wrapper.
-- The cleanest forward path: add a call directly inside install_client_tables
-- in 00_full_schema.sql, but since we can't rewrite that here we call it
-- from a migration-safe DO block and document that 00_full_schema.sql
-- should be updated to include it permanently.

-- For now the DO block above handles existing schemas; new clients provisioned
-- after this migration need:
--   PERFORM sam_admin.install_feature_usage_table(v_schema);
-- added to sam_admin.install_client_tables().  Add to 00_full_schema.sql
-- after the existing PERFORM sam_admin.install_upsert_functions(p_schema) line.


-- -------------------------------------------------------------------------
-- 3. Extend upsert_oracle_extended_discovery to persist feature_usage rows
--    Re-creates the function inside install_extended_views so it stays in
--    sync when install_extended_views is re-run.
-- -------------------------------------------------------------------------

-- We patch install_extended_views by appending an additional EXECUTE block
-- that replaces upsert_oracle_extended_discovery with a version that also
-- upserts into oracle_feature_usage.
--
-- The safest approach without reprinting the 400-line install_extended_views:
-- create a standalone install function for just this upsert extension and
-- call it from the migration + from install_changelog_objects going forward.

CREATE OR REPLACE FUNCTION sam_admin.install_feature_usage_upsert(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  -- Extend upsert_oracle_extended_discovery with feature_usage persistence.
  -- This replaces only the feature_usage section; all other logic (RAC nodes,
  -- PDBs, NUP users) is unchanged.
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.upsert_oracle_extended_discovery(p_payload JSONB)
    RETURNS VOID LANGUAGE plpgsql AS $body$
    DECLARE
      v_server_id   INTEGER;
      v_instance_id INTEGER;
      v_inst        JSONB;
      v_node        JSONB;
      v_pdb         JSONB;
      v_feat        JSONB;
      v_pdb_count   INTEGER;
    BEGIN
      SELECT server_id INTO v_server_id
      FROM   %I.oracle_servers WHERE hostname = p_payload->>'hostname';

      IF v_server_id IS NULL THEN
        RAISE EXCEPTION 'Extended discovery: server %% not found — run base discovery first.',
          p_payload->>'hostname';
      END IF;

      FOR v_inst IN SELECT * FROM jsonb_array_elements(p_payload->'instances')
      LOOP
        SELECT instance_id INTO v_instance_id
        FROM   %I.oracle_instances
        WHERE  server_id = v_server_id
          AND  oracle_sid = v_inst->>'sid';

        IF v_instance_id IS NULL THEN CONTINUE; END IF;

        -- Upsert RAC nodes
        FOR v_node IN SELECT * FROM jsonb_array_elements(COALESCE(v_inst->'rac_nodes', '[]'::jsonb))
        LOOP
          INSERT INTO %I.oracle_rac_nodes
            (instance_id, server_id, node_name, node_number,
             instance_name, last_seen, discovery_run_id)
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
            is_active        = TRUE,
            last_seen        = NOW(),
            discovery_run_id = EXCLUDED.discovery_run_id;
        END LOOP;

        -- Upsert PDB records
        v_pdb_count := 0;
        FOR v_pdb IN SELECT * FROM jsonb_array_elements(COALESCE(v_inst->'pdbs', '[]'::jsonb))
        LOOP
          v_pdb_count := v_pdb_count + 1;
          INSERT INTO %I.oracle_pdbs
            (instance_id, pdb_name, pdb_con_id, open_mode, restricted,
             requires_multitenant_licence, last_seen, discovery_run_id)
          VALUES (
            v_instance_id,
            v_pdb->>'pdb_name',
            (v_pdb->>'con_id')::INTEGER,
            v_pdb->>'open_mode',
            v_pdb->>'restricted',
            (v_pdb_count >= 1 AND (COALESCE(v_pdb->>'con_id', '0') <> '1')),
            NOW(), p_payload->>'run_id'
          )
          ON CONFLICT (instance_id, pdb_name) DO UPDATE SET
            pdb_con_id                   = EXCLUDED.pdb_con_id,
            open_mode                    = EXCLUDED.open_mode,
            restricted                   = EXCLUDED.restricted,
            requires_multitenant_licence = EXCLUDED.requires_multitenant_licence,
            last_seen                    = NOW(),
            discovery_run_id             = EXCLUDED.discovery_run_id;
        END LOOP;

        -- Insert NUP user count snapshot
        IF v_inst ? 'nup_active_users' THEN
          INSERT INTO %I.oracle_nup_users
            (instance_id, snapshot_date, active_user_count,
             total_user_count, locked_user_count,
             sample_user_list, discovery_run_id)
          VALUES (
            v_instance_id,
            CURRENT_DATE,
            (v_inst->>'nup_active_users')::INTEGER,
            (v_inst->>'nup_total_users')::INTEGER,
            (v_inst->>'nup_locked_users')::INTEGER,
            ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_inst->'nup_sample_users', '[]'::jsonb))),
            p_payload->>'run_id'
          );
        END IF;

        -- Upsert feature usage rows from DBA_FEATURE_USAGE_STATISTICS
        FOR v_feat IN SELECT * FROM jsonb_array_elements(COALESCE(v_inst->'feature_usage', '[]'::jsonb))
        LOOP
          INSERT INTO %I.oracle_feature_usage
            (instance_id, feature_name, db_version,
             detected_usages, total_samples, currently_used,
             first_usage_date, last_usage_date, last_sample_date,
             discovery_run_id)
          VALUES (
            v_instance_id,
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
            p_payload->>'run_id'
          )
          ON CONFLICT (instance_id, feature_name) DO UPDATE SET
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
    END;
    $body$;
  $fn$,
  p_schema, p_schema, p_schema,
  p_schema, p_schema, p_schema,
  p_schema, p_schema, p_schema,
  p_schema, p_schema, p_schema);
END;
$$;

-- Install the extended upsert on all existing client schemas
DO $$
DECLARE v_schema TEXT;
BEGIN
  FOR v_schema IN SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_feature_usage_upsert(v_schema);
  END LOOP;
END;
$$;

-- Hook into install_changelog_objects so new clients get it automatically
-- (appended after the existing install_feature_activation_trigger call)
CREATE OR REPLACE FUNCTION sam_admin.install_changelog_objects_post_hook(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  -- Install feature_usage table and extended upsert if not already present
  PERFORM sam_admin.install_feature_usage_table(p_schema);
  PERFORM sam_admin.install_feature_usage_upsert(p_schema);
END;
$$;


-- -------------------------------------------------------------------------
-- 4. Add FEATURE_DORMANT alert to get_compliance_alerts()
--    Fires when a feature has detected_usages > 0 (was used at some point)
--    but last_usage_date is more than 6 months ago — option appears licensed
--    but has not been actively used recently.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION shared.get_compliance_alerts()
RETURNS TABLE (
  alert_type    TEXT,
  severity      TEXT,
  client_code   TEXT,
  client_name   TEXT,
  object_name   TEXT,
  description   TEXT,
  days_until    INTEGER,
  action_needed TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_client RECORD;
  v_row    RECORD;
  v_sql    TEXT;
BEGIN

  -- -------------------------------------------------------------------------
  -- Per-contract / shared alerts (each block guarded independently)
  -- -------------------------------------------------------------------------

  BEGIN
    FOR v_row IN
      SELECT csi_number, contract_name, support_expiry,
             (support_expiry - CURRENT_DATE) AS days_left,
             owning_client, owning_client_name
      FROM   shared.csi_contract_summary
      WHERE  support_status = 'expiring_soon'
    LOOP
      alert_type    := 'SUPPORT_EXPIRING';
      severity      := CASE WHEN v_row.days_left <= 30 THEN 'HIGH' ELSE 'MEDIUM' END;
      client_code   := v_row.owning_client;
      client_name   := v_row.owning_client_name;
      object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
      description   := 'Support expires on ' || v_row.support_expiry::TEXT
                       || ' (' || v_row.days_left || ' days)';
      days_until    := v_row.days_left;
      action_needed := 'Renew support or begin decommission planning';
      RETURN NEXT;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    FOR v_row IN
      SELECT csi_number, contract_name, support_expiry,
             (CURRENT_DATE - support_expiry) AS days_ago,
             owning_client, owning_client_name
      FROM   shared.csi_contract_summary
      WHERE  support_status = 'expired'
    LOOP
      alert_type    := 'SUPPORT_EXPIRED';
      severity      := 'HIGH';
      client_code   := v_row.owning_client;
      client_name   := v_row.owning_client_name;
      object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
      description   := 'Support expired on ' || v_row.support_expiry::TEXT
                       || ' (' || v_row.days_ago || ' days ago)';
      days_until    := -v_row.days_ago;
      action_needed := 'Renew or remove servers from support coverage';
      RETURN NEXT;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    FOR v_row IN
      SELECT csi_number, contract_name, ula_expiry,
             (ula_expiry - CURRENT_DATE) AS days_left,
             owning_client, owning_client_name
      FROM   shared.csi_contract_summary
      WHERE  ula_status = 'ula_expiring'
    LOOP
      alert_type    := 'ULA_EXPIRING';
      severity      := CASE WHEN v_row.days_left <= 60 THEN 'HIGH' ELSE 'MEDIUM' END;
      client_code   := v_row.owning_client;
      client_name   := v_row.owning_client_name;
      object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
      description   := 'ULA expires on ' || v_row.ula_expiry::TEXT
                       || ' (' || v_row.days_left || ' days). Certification must be completed before expiry.';
      days_until    := v_row.days_left;
      action_needed := 'Begin ULA certification process or negotiate renewal';
      RETURN NEXT;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    FOR v_row IN
      SELECT csi_number, contract_name, ula_expiry,
             (CURRENT_DATE - ula_expiry) AS days_ago,
             owning_client, owning_client_name
      FROM   shared.csi_contract_summary
      WHERE  ula_status = 'ula_expired'
    LOOP
      alert_type    := 'ULA_EXPIRED';
      severity      := 'CRITICAL';
      client_code   := v_row.owning_client;
      client_name   := v_row.owning_client_name;
      object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
      description   := 'ULA expired on ' || v_row.ula_expiry::TEXT
                       || ' (' || v_row.days_ago || ' days ago) without certification.';
      days_until    := -v_row.days_ago;
      action_needed := 'Certify immediately or revert to named-user/processor licensing';
      RETURN NEXT;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    FOR v_row IN
      SELECT csi_number, contract_name, allocation_status, product_families
      FROM   shared.unassigned_licences
    LOOP
      alert_type    := 'UNASSIGNED_LICENCE';
      severity      := 'MEDIUM';
      client_code   := NULL;
      client_name   := NULL;
      object_name   := v_row.csi_number || ' — ' || v_row.contract_name;
      description   := v_row.allocation_status || ': '
                       || COALESCE(v_row.product_families, 'unknown product');
      days_until    := NULL;
      action_needed := CASE v_row.allocation_status
        WHEN 'NEEDS POLICY'     THEN 'Set sharing_policy via shared.set_csi_owner() or shared.assign_csi_to_client()'
        WHEN 'NEEDS ASSIGNMENT' THEN 'Assign this CSI to a client via shared.assign_csi_to_client()'
        ELSE 'Review and assign'
      END;
      RETURN NEXT;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    FOR v_row IN
      SELECT cluster_name, vcenter_host, client_code,
             host_count, total_sockets, total_physical_cores,
             oracle_db_vm_count, oracle_wls_vm_count
      FROM   sam_admin.vmware_licence_exposure
      WHERE  has_oracle_workloads = TRUE
    LOOP
      alert_type    := 'VMWARE_CLUSTER_EXPOSURE';
      severity      := 'HIGH';
      client_code   := v_row.client_code;
      client_name   := NULL;
      object_name   := v_row.cluster_name || ' @ ' || v_row.vcenter_host;
      description   := 'VMware cluster has ' || v_row.oracle_db_vm_count
                       || ' Oracle DB VM(s) and ' || v_row.oracle_wls_vm_count
                       || ' WLS VM(s) across ' || v_row.host_count || ' hosts ('
                       || v_row.total_sockets || ' sockets / '
                       || v_row.total_physical_cores || ' cores total). '
                       || 'Oracle requires the entire cluster to be licensed.';
      days_until    := NULL;
      action_needed := 'Verify licences cover all ' || v_row.total_physical_cores
                       || ' physical cores in this vSphere cluster, or implement Oracle-approved hard partitioning';
      RETURN NEXT;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- -------------------------------------------------------------------------
  -- Per-client-schema alerts
  -- -------------------------------------------------------------------------

  FOR v_client IN
    SELECT c.schema_name, c.client_code, c.client_name
    FROM   sam_admin.clients c
    WHERE  c.is_active
  LOOP

    BEGIN
      v_sql := format(
        $q$SELECT s.hostname, p.cpu_model
           FROM   %I.oracle_servers s
           JOIN   LATERAL (
             SELECT cpu_model FROM %I.oracle_processors
             WHERE  server_id = s.server_id
             ORDER  BY recorded_at DESC LIMIT 1
           ) p ON TRUE
           WHERE  s.is_active
             AND  p.cpu_model IS NOT NULL
             AND  shared.cpu_core_factor_lookup(p.cpu_model) IS NULL$q$,
        v_client.schema_name, v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'UNRECOGNISED_CPU';
        severity      := 'MEDIUM';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.hostname;
        description   := 'CPU model "' || v_row.cpu_model
                         || '" does not match any entry in the Oracle Processor Core Factor Table';
        days_until    := NULL;
        action_needed := 'Verify correct core factor at oracle.com/assets/processor-core-factor-table-070634.pdf and add to shared.core_factor_table';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
      v_sql := format(
        $q$SELECT hostname, first_seen FROM %I.oracle_servers
           WHERE is_active AND first_seen >= NOW() - INTERVAL '7 days'$q$,
        v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'NEW_SERVER_DETECTED';
        severity      := 'MEDIUM';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.hostname;
        description   := 'New server first detected on ' || v_row.first_seen::DATE::TEXT;
        days_until    := NULL;
        action_needed := 'Verify server is known, assign to a contract, and confirm licensing coverage';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
      v_sql := format(
        $q$SELECT s.hostname
           FROM   %I.oracle_servers s
           WHERE  s.is_active
             AND  (s.virtualization_type ILIKE '%%vmware%%'
                   OR s.virtualization_type ILIKE '%%vsphere%%'
                   OR s.virtualization_type ILIKE '%%esxi%%')
             AND  NOT EXISTS (
               SELECT 1 FROM %I.server_csi_map m
               JOIN shared.csi_contracts c ON c.csi_id = m.csi_id
               WHERE m.server_id = s.server_id AND c.is_ula = TRUE
             )$q$,
        v_client.schema_name, v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'VMWARE_SERVER_NO_ULA';
        severity      := 'HIGH';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.hostname;
        description   := 'VMware-hosted Oracle server has no ULA licence assignment';
        days_until    := NULL;
        action_needed := 'Assign a ULA contract or verify Oracle-approved hard partitioning is in place';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
      v_sql := format(
        $q$SELECT cl.server_id, s.hostname, cl.field_changed, cl.old_value, cl.new_value, cl.detected_at
           FROM   %I.discovery_changelog cl
           JOIN   %I.oracle_servers s ON s.server_id = cl.server_id
           WHERE  cl.change_category = 'hardware'
             AND  cl.field_changed IN ('cpu_cores','total_cores','cpu_sockets','physical_cores')
             AND  cl.new_value::NUMERIC > cl.old_value::NUMERIC
             AND  COALESCE(cl.acknowledged, FALSE) = FALSE
             AND  cl.detected_at >= NOW() - INTERVAL '30 days'$q$,
        v_client.schema_name, v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'HARDWARE_INCREASE';
        severity      := 'HIGH';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.hostname;
        description   := v_row.field_changed || ' increased from ' || v_row.old_value
                         || ' to ' || v_row.new_value
                         || ' (detected ' || v_row.detected_at::DATE::TEXT || ')';
        days_until    := NULL;
        action_needed := 'Review licence coverage for increased compute capacity and acknowledge change';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
      v_sql := format(
        $q$SELECT cl.server_id, s.hostname, cl.field_changed, cl.old_value, cl.new_value, cl.detected_at
           FROM   %I.discovery_changelog cl
           JOIN   %I.oracle_servers s ON s.server_id = cl.server_id
           WHERE  cl.change_category = 'hardware'
             AND  cl.field_changed IN ('cpu_cores','total_cores','cpu_sockets','physical_cores')
             AND  cl.new_value::NUMERIC < cl.old_value::NUMERIC
             AND  COALESCE(cl.acknowledged, FALSE) = FALSE
             AND  cl.detected_at >= NOW() - INTERVAL '30 days'$q$,
        v_client.schema_name, v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'HARDWARE_DECREASE';
        severity      := 'MEDIUM';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.hostname;
        description   := v_row.field_changed || ' decreased from ' || v_row.old_value
                         || ' to ' || v_row.new_value
                         || ' (detected ' || v_row.detected_at::DATE::TEXT || ')';
        days_until    := NULL;
        action_needed := 'Confirm change is intentional and acknowledge — may allow licence reductions';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
      v_sql := format(
        $q$SELECT cl.server_id, s.hostname, cl.object_name AS feature_name, cl.new_value, cl.detected_at
           FROM   %I.discovery_changelog cl
           JOIN   %I.oracle_servers s ON s.server_id = cl.server_id
           WHERE  cl.change_category IN ('option','feature','oracle_option')
             AND  cl.change_type IN ('NEW','ADDED','ENABLED')
             AND  COALESCE(cl.acknowledged, FALSE) = FALSE
             AND  cl.detected_at >= NOW() - INTERVAL '30 days'$q$,
        v_client.schema_name, v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'NEW_OPTION_ENABLED';
        severity      := 'HIGH';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.hostname;
        description   := 'Oracle option/feature "' || COALESCE(v_row.feature_name, v_row.new_value)
                         || '" newly enabled (detected ' || v_row.detected_at::DATE::TEXT || ')';
        days_until    := NULL;
        action_needed := 'Verify this option is licenced or disable it immediately';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- Alert: licensed feature present on server but not actively used for > 6 months.
    -- Sourced from oracle_feature_usage (persisted DBA_FEATURE_USAGE_STATISTICS).
    -- Only fires when detected_usages > 0 (it was used at some point) AND
    -- last_usage_date is more than 6 months ago — indicating a potentially
    -- unnecessary licence that could be reclaimed.
    BEGIN
      v_sql := format(
        $q$SELECT DISTINCT ON (f.feature_name)
                  s.hostname,
                  i.oracle_sid,
                  f.feature_name,
                  f.last_usage_date,
                  f.first_usage_date,
                  (CURRENT_DATE - f.last_usage_date) AS days_since_use
           FROM   %I.oracle_feature_usage f
           JOIN   %I.oracle_instances i ON i.instance_id = f.instance_id
           JOIN   %I.oracle_servers   s ON s.server_id   = i.server_id
           WHERE  f.detected_usages > 0
             AND  f.last_usage_date IS NOT NULL
             AND  f.last_usage_date < CURRENT_DATE - INTERVAL '6 months'
             AND  s.is_active = TRUE
           ORDER  BY f.feature_name, f.last_usage_date DESC$q$,
        v_client.schema_name, v_client.schema_name, v_client.schema_name
      );
      FOR v_row IN EXECUTE v_sql LOOP
        alert_type    := 'FEATURE_DORMANT';
        severity      := 'MEDIUM';
        client_code   := v_client.client_code;
        client_name   := v_client.client_name;
        object_name   := v_row.hostname || ' / ' || v_row.oracle_sid;
        description   := '"' || v_row.feature_name || '" last used '
                         || v_row.last_usage_date::TEXT
                         || ' (' || v_row.days_since_use || ' days ago).'
                         || ' First used ' || v_row.first_usage_date::TEXT || '.';
        days_until    := NULL;
        action_needed := 'Confirm feature is still required. If unused, disable it to '
                         || 'reduce licence exposure or reclaim the entitlement.';
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

  END LOOP;

END;
$$;

CREATE OR REPLACE VIEW shared.compliance_alerts AS
SELECT * FROM shared.get_compliance_alerts();

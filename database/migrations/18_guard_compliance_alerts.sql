-- Migration 18: Guard shared blocks in get_compliance_alerts()
--
-- The per-contract alert blocks (support/ULA expiry, unassigned licences,
-- VMware cluster exposure) were not wrapped in BEGIN...EXCEPTION guards.
-- If any dependent view (e.g. shared.unassigned_licences,
-- sam_admin.vmware_licence_exposure) does not exist the entire function
-- raises an exception and no alerts are returned.
--
-- This migration wraps every shared block with the same
-- EXCEPTION WHEN OTHERS THEN NULL pattern already used in the per-client
-- blocks so missing optional views degrade gracefully.

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
  -- Per-contract / shared alerts
  -- Each block is independently guarded so a missing view or table does not
  -- prevent the remaining alerts from being returned.
  -- -------------------------------------------------------------------------

  -- Alert: support expiring within 90 days
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

  -- Alert: support already expired
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

  -- Alert: ULA expiring within 180 days
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

  -- Alert: ULA already expired without certification
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

  -- Alert: licences with no policy or no client assignment
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

  -- Alert: VMware clusters with Oracle workloads
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

  FOR v_client IN SELECT c.schema_name, c.client_code, c.client_name FROM sam_admin.clients c WHERE c.is_active LOOP

    -- Alert: servers with unrecognised CPU model
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

    -- Alert: new servers detected in the last 7 days
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

    -- Alert: VMware-hosted Oracle servers with no ULA assignment
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

    -- Alert: hardware increases (unacknowledged, last 30 days)
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

    -- Alert: hardware decreases (unacknowledged, last 30 days)
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

    -- Alert: new Oracle options/features enabled (unacknowledged, last 30 days)
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

  END LOOP;

END;
$$;

CREATE OR REPLACE VIEW shared.compliance_alerts AS
SELECT * FROM shared.get_compliance_alerts();

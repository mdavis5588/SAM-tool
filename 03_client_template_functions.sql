-- =============================================================================
-- Client Template Functions
-- Replaces the stub implementations in 01_admin_schema.sql.
-- Run AFTER both 01_admin_schema.sql and 02_shared_schema.sql.
-- These functions are called by sam_admin.provision_client() for every new
-- client, and also by sam_admin.migrate_all_clients() for upgrades.
-- =============================================================================

SET search_path = sam_admin, shared, public;

-- ---------------------------------------------------------------------------
-- INSTALL LICENSE POSITION VIEW
-- Creates the licence calculation view inside a specific client schema.
-- Joins to shared.core_factor_table and shared.entitlement_client_map so
-- that each client only sees entitlements assigned to them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.install_license_position_view(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($view$
    CREATE OR REPLACE VIEW %I.license_position AS

    WITH client_ref AS (
      -- Identify the client_id for this schema
      SELECT client_id FROM sam_admin.clients WHERE schema_name = %L
    ),

    latest_proc AS (
      SELECT DISTINCT ON (server_id)
        server_id, cpu_model, cpu_sockets, cores_per_socket,
        total_physical_cores, virt_type, is_vmware
      FROM %I.oracle_processors
      ORDER BY server_id, recorded_at DESC
    ),

    core_factor AS (
      SELECT
        lp.server_id,
        lp.cpu_model,
        lp.cpu_sockets,
        lp.cores_per_socket,
        lp.total_physical_cores,
        lp.virt_type,
        lp.is_vmware,
        COALESCE(
          (SELECT cf.core_factor
           FROM   shared.core_factor_table cf
           WHERE  lp.cpu_model ILIKE cf.processor_pattern
             AND  cf.processor_pattern <> 'Unknown'
             AND  cf.is_current = TRUE
           ORDER  BY cf.effective_date DESC LIMIT 1),
          (SELECT cf.core_factor FROM shared.core_factor_table cf
           WHERE  cf.processor_pattern = 'Unknown' LIMIT 1),
          0.5
        ) AS core_factor
      FROM latest_proc lp
    ),

    -- Oracle Database licence requirement per instance
    db_required AS (
      SELECT
        s.server_id,
        s.hostname,
        s.environment::TEXT,
        'oracle_database'::TEXT    AS product_family,
        i.edition                  AS product_detail,
        cf.cpu_sockets,
        cf.total_physical_cores,
        cf.cpu_model,
        cf.core_factor,
        cf.virt_type::TEXT,
        cf.is_vmware,
        CASE
          WHEN i.edition ILIKE '%%Enterprise%%' THEN
            ROUND(cf.total_physical_cores * cf.core_factor, 2)
          WHEN i.edition ILIKE '%%Standard Edition 2%%' THEN
            LEAST(cf.cpu_sockets, 2)::NUMERIC
          WHEN i.edition ILIKE '%%Standard%%' THEN
            cf.cpu_sockets::NUMERIC
          ELSE ROUND(cf.total_physical_cores * cf.core_factor, 2)
        END AS licences_required
      FROM   %I.oracle_servers     s
      JOIN   %I.oracle_instances   i ON i.server_id = s.server_id AND i.is_active
      JOIN   core_factor           cf ON cf.server_id = s.server_id
      WHERE  s.is_active = TRUE
    ),

    -- WebLogic licence requirement per domain
    wls_required AS (
      SELECT
        s.server_id,
        s.hostname,
        s.environment::TEXT,
        'oracle_weblogic'::TEXT    AS product_family,
        d.wls_edition              AS product_detail,
        cf.cpu_sockets,
        cf.total_physical_cores,
        cf.cpu_model,
        cf.core_factor,
        cf.virt_type::TEXT,
        cf.is_vmware,
        CASE
          WHEN lr.uses_core_factor THEN
            ROUND(cf.total_physical_cores * cf.core_factor, 2)
          ELSE
            cf.cpu_sockets::NUMERIC
        END AS licences_required
      FROM   %I.oracle_servers     s
      JOIN   %I.wls_domains        d ON d.server_id = s.server_id AND d.is_active
      JOIN   core_factor           cf ON cf.server_id = s.server_id
      LEFT   JOIN LATERAL (
        SELECT uses_core_factor
        FROM   shared.wls_license_rules r
        WHERE  d.wls_edition ILIKE r.edition_pattern
        ORDER  BY LENGTH(r.edition_pattern) DESC LIMIT 1
      ) lr ON TRUE
      WHERE  s.is_active = TRUE
    ),

    all_required AS (
      SELECT * FROM db_required
      UNION ALL
      SELECT * FROM wls_required
    ),

    -- Entitlements visible to this client
    client_entitlements AS (
      SELECT
        e.product_name,
        e.product_family::TEXT,
        e.license_metric,
        COALESCE(m.allocated_quantity, e.quantity) AS available_quantity
      FROM   shared.license_entitlements     e
      JOIN   shared.entitlement_client_map   m ON m.entitlement_id = e.entitlement_id
      JOIN   client_ref                      cr ON cr.client_id = m.client_id
      WHERE  e.status = 'active'
    ),

    entitlement_totals AS (
      SELECT
        product_family,
        SUM(available_quantity) AS total_licensed
      FROM   client_entitlements
      GROUP  BY product_family
    )

    SELECT
      ar.server_id,
      ar.hostname,
      ar.environment,
      ar.product_family,
      ar.product_detail,
      ar.cpu_sockets,
      ar.total_physical_cores,
      ar.cpu_model,
      ar.core_factor,
      ar.virt_type,
      ar.is_vmware,
      ar.licences_required,
      COALESCE(et.total_licensed, 0)             AS total_licensed,
      COALESCE(et.total_licensed, 0)
        - SUM(ar.licences_required) OVER (PARTITION BY ar.product_family)
                                                 AS licence_surplus_deficit,
      CASE
        WHEN COALESCE(et.total_licensed, 0)
           - SUM(ar.licences_required) OVER (PARTITION BY ar.product_family) >= 0
        THEN 'compliant'
        ELSE 'under_licensed'
      END                                        AS compliance_status
    FROM   all_required ar
    LEFT   JOIN entitlement_totals et ON et.product_family = ar.product_family
    ORDER  BY ar.product_family, ar.environment, ar.hostname;

  $view$,
  p_schema,   -- view schema
  p_schema,   -- client_ref WHERE schema_name
  p_schema,   -- oracle_processors
  p_schema,   -- oracle_servers (db_required)
  p_schema,   -- oracle_instances
  p_schema,   -- oracle_servers (wls_required)
  p_schema    -- wls_domains
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- INSTALL UPSERT FUNCTIONS
-- Creates the data-load functions that Ansible calls, inside each client schema.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.install_upsert_functions(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN

  -- upsert_oracle_discovery: called by the Oracle DB Ansible playbook
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.upsert_oracle_discovery(p_payload JSONB)
    RETURNS VOID LANGUAGE plpgsql AS $body$
    DECLARE
      v_server_id  INTEGER;
      v_instance   JSONB;
    BEGIN
      -- Upsert server
      INSERT INTO %I.oracle_servers
        (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
         environment, criticality, total_ram_mb, datacenter,
         last_seen, last_discovery_run)
      VALUES (
        p_payload->>'hostname',
        p_payload->>'fqdn',
        (p_payload->>'ip_address')::INET,
        p_payload->>'os_family',
        p_payload->>'os_distribution',
        p_payload->>'os_version',
        (p_payload->>'environment')::%%I.environment_type,
        p_payload->>'criticality',
        (p_payload->>'total_ram_mb')::INTEGER,
        p_payload->>'datacenter',
        NOW(),
        p_payload->>'run_id'
      )
      ON CONFLICT (hostname) DO UPDATE SET
        fqdn               = EXCLUDED.fqdn,
        ip_address         = EXCLUDED.ip_address,
        os_family          = EXCLUDED.os_family,
        os_distribution    = EXCLUDED.os_distribution,
        os_version         = EXCLUDED.os_version,
        environment        = EXCLUDED.environment,
        criticality        = EXCLUDED.criticality,
        total_ram_mb       = EXCLUDED.total_ram_mb,
        datacenter         = EXCLUDED.datacenter,
        last_seen          = NOW(),
        last_discovery_run = EXCLUDED.last_discovery_run
      RETURNING server_id INTO v_server_id;

      -- Insert processor snapshot
      INSERT INTO %I.oracle_processors
        (server_id, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
         threads_per_core, virt_type, is_vmware, vcpu_count, discovery_run_id)
      VALUES (
        v_server_id,
        p_payload->>'cpu_model',
        p_payload->>'cpu_architecture',
        (p_payload->>'cpu_sockets')::INTEGER,
        (p_payload->>'cpu_cores_per_socket')::INTEGER,
        (p_payload->>'cpu_threads_per_core')::INTEGER,
        (COALESCE(p_payload->>'virt_type','unknown'))::%%I.virt_type,
        (p_payload->>'is_vmware')::BOOLEAN,
        (p_payload->>'vcpu_count')::INTEGER,
        p_payload->>'run_id'
      );

      -- Upsert Oracle instances
      FOR v_instance IN SELECT * FROM jsonb_array_elements(p_payload->'instances')
      LOOP
        INSERT INTO %I.oracle_instances
          (server_id, oracle_sid, db_name, edition, db_version,
           platform_name, last_seen, discovery_run_id)
        VALUES (
          v_server_id,
          v_instance->>'sid',
          v_instance->>'db_name',
          v_instance->>'edition',
          v_instance->>'version',
          v_instance->>'platform_name',
          NOW(),
          p_payload->>'run_id'
        )
        ON CONFLICT (server_id, oracle_sid) DO UPDATE SET
          edition          = EXCLUDED.edition,
          db_version       = EXCLUDED.db_version,
          platform_name    = EXCLUDED.platform_name,
          last_seen        = NOW(),
          discovery_run_id = EXCLUDED.discovery_run_id;
      END LOOP;
    END;
    $body$;
  $fn$,
  p_schema, p_schema, p_schema, p_schema, p_schema, p_schema, p_schema);

  -- upsert_wls_discovery: called by the WebLogic Ansible playbook
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.upsert_wls_discovery(p_payload JSONB)
    RETURNS VOID LANGUAGE plpgsql AS $body$
    DECLARE
      v_server_id  INTEGER;
      v_domain_id  INTEGER;
      v_domain     JSONB;
      v_ms         JSONB;
      v_product    JSONB;
    BEGIN
      -- Ensure server record exists (WLS discovery may run separately from DB discovery)
      INSERT INTO %I.oracle_servers
        (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
         environment, criticality, total_ram_mb, datacenter,
         last_seen, last_discovery_run)
      VALUES (
        p_payload->>'hostname', p_payload->>'fqdn',
        (p_payload->>'ip_address')::INET,
        p_payload->>'os_family', p_payload->>'os_distribution', p_payload->>'os_version',
        (p_payload->>'environment')::%%I.environment_type,
        p_payload->>'criticality',
        (p_payload->>'total_ram_mb')::INTEGER,
        p_payload->>'datacenter',
        NOW(), p_payload->>'run_id'
      )
      ON CONFLICT (hostname) DO UPDATE SET
        last_seen          = NOW(),
        last_discovery_run = EXCLUDED.last_discovery_run
      RETURNING server_id INTO v_server_id;

      -- Upsert processor info if provided
      IF p_payload ? 'cpu_sockets' THEN
        INSERT INTO %I.oracle_processors
          (server_id, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
           threads_per_core, virt_type, is_vmware, vcpu_count, discovery_run_id)
        VALUES (
          v_server_id,
          p_payload->>'cpu_model',
          p_payload->>'cpu_architecture',
          (p_payload->>'cpu_sockets')::INTEGER,
          (p_payload->>'cpu_cores_per_socket')::INTEGER,
          (p_payload->>'cpu_threads_per_core')::INTEGER,
          (COALESCE(p_payload->>'virt_type','unknown'))::%%I.virt_type,
          (p_payload->>'is_vmware')::BOOLEAN,
          (p_payload->>'vcpu_count')::INTEGER,
          p_payload->>'run_id'
        );
      END IF;

      -- Upsert WLS domains
      FOR v_domain IN SELECT * FROM jsonb_array_elements(p_payload->'domains')
      LOOP
        INSERT INTO %I.wls_domains
          (server_id, domain_name, domain_home, wls_version, wls_edition,
           admin_server_host, admin_server_port, last_seen, discovery_run_id)
        VALUES (
          v_server_id,
          v_domain->>'domain_name',
          v_domain->>'domain_home',
          v_domain->>'wls_version',
          v_domain->>'wls_edition',
          v_domain->>'admin_server_host',
          (v_domain->>'admin_server_port')::INTEGER,
          NOW(),
          p_payload->>'run_id'
        )
        ON CONFLICT (server_id, domain_name) DO UPDATE SET
          domain_home          = EXCLUDED.domain_home,
          wls_version          = EXCLUDED.wls_version,
          wls_edition          = EXCLUDED.wls_edition,
          admin_server_host    = EXCLUDED.admin_server_host,
          admin_server_port    = EXCLUDED.admin_server_port,
          last_seen            = NOW(),
          discovery_run_id     = EXCLUDED.discovery_run_id
        RETURNING domain_id INTO v_domain_id;

        -- Upsert managed servers for this domain
        FOR v_ms IN SELECT * FROM jsonb_array_elements(v_domain->'managed_servers')
        LOOP
          INSERT INTO %I.wls_managed_servers
            (domain_id, server_id, managed_server_name, listen_port,
             ssl_port, cluster_name, machine_name, state,
             last_seen, discovery_run_id)
          VALUES (
            v_domain_id, v_server_id,
            v_ms->>'name',
            (v_ms->>'listen_port')::INTEGER,
            (v_ms->>'ssl_port')::INTEGER,
            v_ms->>'cluster',
            v_ms->>'machine',
            v_ms->>'state',
            NOW(), p_payload->>'run_id'
          )
          ON CONFLICT DO NOTHING;
        END LOOP;

        -- Upsert installed products
        FOR v_product IN SELECT * FROM jsonb_array_elements(v_domain->'installed_products')
        LOOP
          INSERT INTO %I.wls_installed_products
            (domain_id, product_name, product_version, home_path, discovery_run_id)
          VALUES (
            v_domain_id,
            v_product->>'name',
            v_product->>'version',
            v_product->>'home',
            p_payload->>'run_id'
          );
        END LOOP;
      END LOOP;
    END;
    $body$;
  $fn$,
  p_schema,
  p_schema, p_schema,
  p_schema,
  p_schema, p_schema,
  p_schema,
  p_schema,
  p_schema);

END;
$$;

-- ---------------------------------------------------------------------------
-- MIGRATE ALL CLIENTS
-- Re-installs views and functions across all client schemas.
-- Run after any schema change.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.migrate_all_clients()
RETURNS TABLE (client_code TEXT, result TEXT) LANGUAGE plpgsql AS $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN
    SELECT client_code, schema_name FROM sam_admin.clients WHERE is_active = TRUE
  LOOP
    BEGIN
      PERFORM sam_admin.install_license_position_view(v_client.schema_name);
      PERFORM sam_admin.install_upsert_functions(v_client.schema_name);
      client_code := v_client.client_code;
      result      := 'ok';
      RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
      client_code := v_client.client_code;
      result      := 'ERROR: ' || SQLERRM;
      RETURN NEXT;
    END;
  END LOOP;
  PERFORM shared.refresh_cross_client_summary();
END;
$$;

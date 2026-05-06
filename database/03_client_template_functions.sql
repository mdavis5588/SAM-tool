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
        lp.server_id, lp.cpu_model, lp.cpu_sockets, lp.cores_per_socket,
        lp.total_physical_cores, lp.virt_type, lp.is_vmware,
        COALESCE(
          (SELECT cf.core_factor FROM shared.core_factor_table cf
           WHERE  lp.cpu_model ILIKE cf.processor_pattern
             AND  cf.processor_pattern <> 'Unknown' AND cf.is_current = TRUE
           ORDER  BY cf.effective_date DESC LIMIT 1),
          (SELECT cf.core_factor FROM shared.core_factor_table cf
           WHERE  cf.processor_pattern = 'Unknown' LIMIT 1),
          0.5
        ) AS core_factor
      FROM latest_proc lp
    ),

    -- Licences required per server/product
    db_required AS (
      SELECT
        s.server_id, s.hostname, s.environment::TEXT,
        'oracle_database'::TEXT AS product_family,
        i.edition               AS product_detail,
        cf.cpu_sockets, cf.total_physical_cores, cf.cpu_model,
        cf.core_factor, cf.virt_type::TEXT, cf.is_vmware,
        CASE
          WHEN i.edition ILIKE '%%Enterprise%%'         THEN ROUND(cf.total_physical_cores * cf.core_factor, 2)
          WHEN i.edition ILIKE '%%Standard Edition 2%%' THEN LEAST(cf.cpu_sockets, 2)::NUMERIC
          WHEN i.edition ILIKE '%%Standard%%'           THEN cf.cpu_sockets::NUMERIC
          ELSE ROUND(cf.total_physical_cores * cf.core_factor, 2)
        END AS licences_required
      FROM %I.oracle_servers s
      JOIN %I.oracle_instances i ON i.server_id = s.server_id AND i.is_active
      JOIN core_factor cf        ON cf.server_id = s.server_id
      WHERE s.is_active = TRUE
    ),

    wls_required AS (
      SELECT
        s.server_id, s.hostname, s.environment::TEXT,
        'oracle_weblogic'::TEXT AS product_family,
        d.wls_edition           AS product_detail,
        cf.cpu_sockets, cf.total_physical_cores, cf.cpu_model,
        cf.core_factor, cf.virt_type::TEXT, cf.is_vmware,
        CASE
          WHEN lr.uses_core_factor THEN ROUND(cf.total_physical_cores * cf.core_factor, 2)
          ELSE cf.cpu_sockets::NUMERIC
        END AS licences_required
      FROM %I.oracle_servers s
      JOIN %I.wls_domains d ON d.server_id = s.server_id AND d.is_active
      JOIN core_factor cf   ON cf.server_id = s.server_id
      LEFT JOIN LATERAL (
        SELECT uses_core_factor FROM shared.wls_license_rules r
        WHERE  d.wls_edition ILIKE r.edition_pattern
        ORDER  BY LENGTH(r.edition_pattern) DESC LIMIT 1
      ) lr ON TRUE
      WHERE s.is_active = TRUE
    ),

    all_required AS (
      SELECT * FROM db_required UNION ALL SELECT * FROM wls_required
    ),

    -- Explicit CSI assignments for each server from server_csi_map
    server_assignments AS (
      SELECT
        scm.server_id,
        scm.csi_id,
        scm.line_id,
        scm.product_family,
        scm.licences_consumed,
        cs.contract_name,
        cs.csi_number,
        cs.sharing_policy::TEXT
      FROM %I.server_csi_map scm
      JOIN shared.csi_contracts cs ON cs.csi_id = scm.csi_id
    ),

    -- Total licences available to this client from csi_client_map,
    -- grouped by product_family across all assigned CSI lines
    client_entitlements AS (
      SELECT
        l.product_family::TEXT,
        SUM(
          CASE
            WHEN m.allocated_quantity IS NULL THEN l.quantity
            ELSE ROUND(
              l.quantity * m.allocated_quantity
              / NULLIF((SELECT SUM(q.quantity)
                        FROM shared.license_entitlement_lines q
                        WHERE q.csi_id = l.csi_id AND q.is_active), 0),
              2)
          END
        ) AS total_licensed
      FROM   shared.csi_contracts             cs
      JOIN   shared.csi_client_map            m  ON m.csi_id    = cs.csi_id
      JOIN   client_ref                       cr ON cr.client_id = m.client_id
      JOIN   shared.license_entitlement_lines l  ON l.csi_id    = cs.csi_id AND l.is_active
      WHERE  cs.status = 'active'
      GROUP  BY l.product_family
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

      -- Which CSIs explicitly cover this server/product combination
      (SELECT STRING_AGG(sa.csi_number || ' (' || sa.contract_name || ')', ', '
                         ORDER BY sa.csi_number)
       FROM   server_assignments sa
       WHERE  sa.server_id = ar.server_id
         AND  sa.product_family = ar.product_family
      )                                              AS assigned_csi_numbers,

      -- Count of explicit CSI assignments for this server/product
      (SELECT COUNT(*)
       FROM   server_assignments sa
       WHERE  sa.server_id = ar.server_id
         AND  sa.product_family = ar.product_family
      )                                              AS csi_assignment_count,

      -- Is this server explicitly mapped, or relying on the pool?
      CASE
        WHEN EXISTS (
          SELECT 1 FROM server_assignments sa
          WHERE sa.server_id = ar.server_id AND sa.product_family = ar.product_family
        ) THEN TRUE ELSE FALSE
      END                                            AS has_explicit_csi,

      COALESCE(et.total_licensed, 0)                 AS total_licensed,
      COALESCE(et.total_licensed, 0)
        - SUM(ar.licences_required) OVER (PARTITION BY ar.product_family)
                                                     AS licence_surplus_deficit,
      CASE
        WHEN COALESCE(et.total_licensed, 0)
           - SUM(ar.licences_required) OVER (PARTITION BY ar.product_family) >= 0
        THEN 'compliant'
        ELSE 'under_licensed'
      END                                            AS compliance_status

    FROM   all_required ar
    LEFT   JOIN client_entitlements et ON et.product_family = ar.product_family
    ORDER  BY ar.product_family, ar.environment, ar.hostname;

  $view$,
  p_schema,   -- view schema
  p_schema,   -- client_ref WHERE schema_name
  p_schema,   -- oracle_processors
  p_schema,   -- oracle_servers (db_required)
  p_schema,   -- oracle_instances
  p_schema,   -- oracle_servers (wls_required)
  p_schema,   -- wls_domains
  p_schema    -- server_csi_map
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- INSTALL LICENSE OPTIONS VIEW
-- Creates the licence_metric_comparison view in each client schema.
-- Shows, for every server and product, what the licence requirement would be
-- under EACH Oracle metric side-by-side:
--   - Processor Perpetual  (physical cores × core factor)
--   - Named User Plus      (physical cores × core factor × 25 minimum NUP per core)
--   - SE2 Processor        (sockets, capped at 2)
-- This is purely informational — it does not affect the compliance calculation
-- in license_position. Use it for "what if" analysis and audit prep.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.install_license_options_view(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($view$
    CREATE OR REPLACE VIEW %I.license_metric_comparison AS

    -- Oracle rules for Named User Plus minimums:
    --   Enterprise Edition : 25 NUP per processor licence (i.e. per core × core_factor)
    --   Standard Edition 2 : 10 NUP per processor licence (per occupied socket, max 2)
    -- Source: Oracle Technology Global Price List

    WITH latest_proc AS (
      SELECT DISTINCT ON (server_id)
        server_id, cpu_model, cpu_sockets, cores_per_socket,
        total_physical_cores, virt_type, is_vmware
      FROM %I.oracle_processors
      ORDER BY server_id, recorded_at DESC
    ),

    cf AS (
      SELECT
        lp.server_id,
        lp.cpu_model,
        lp.cpu_sockets,
        lp.cores_per_socket,
        lp.total_physical_cores,
        lp.virt_type,
        lp.is_vmware,
        COALESCE(
          (SELECT c.core_factor
           FROM   shared.core_factor_table c
           WHERE  lp.cpu_model ILIKE c.processor_pattern
             AND  c.processor_pattern <> 'Unknown'
             AND  c.is_current = TRUE
           ORDER  BY c.effective_date DESC LIMIT 1),
          (SELECT c.core_factor FROM shared.core_factor_table c
           WHERE  c.processor_pattern = 'Unknown' LIMIT 1),
          0.5
        ) AS core_factor
      FROM latest_proc lp
    ),

    -- ---- Oracle Database rows ----
    db_rows AS (
      SELECT
        s.server_id,
        s.hostname,
        s.environment::TEXT,
        s.datacenter,
        'oracle_database'::TEXT                         AS product_family,
        i.edition                                       AS product_detail,
        i.db_version                                    AS product_version,
        cf.cpu_model,
        cf.cpu_sockets,
        cf.cores_per_socket,
        cf.total_physical_cores,
        cf.core_factor,
        cf.virt_type::TEXT,
        cf.is_vmware,

        -- Processor Perpetual (EE)
        ROUND(cf.total_physical_cores * cf.core_factor, 2)
                                                        AS proc_perpetual_ee,

        -- Processor Perpetual (SE2) — sockets capped at 2
        LEAST(cf.cpu_sockets, 2)::NUMERIC               AS proc_perpetual_se2,

        -- Named User Plus — EE minimum: 25 NUP per processor licence
        -- NUP licences must be >= (proc_perpetual_ee × 25)
        ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
                                                        AS nup_minimum_ee,

        -- Named User Plus — SE2 minimum: 10 NUP per processor licence
        LEAST(cf.cpu_sockets, 2) * 10                  AS nup_minimum_se2,

        -- Which metric this instance is currently licensed under
        CASE
          WHEN i.edition ILIKE '%%Enterprise%%'        THEN 'processor_ee'
          WHEN i.edition ILIKE '%%Standard Edition 2%%' THEN 'processor_se2'
          WHEN i.edition ILIKE '%%Standard%%'          THEN 'processor_se'
          ELSE 'processor_ee'
        END                                             AS current_metric,

        -- Licences required under the CURRENT metric (matches license_position)
        CASE
          WHEN i.edition ILIKE '%%Enterprise%%' THEN
            ROUND(cf.total_physical_cores * cf.core_factor, 2)
          WHEN i.edition ILIKE '%%Standard Edition 2%%' THEN
            LEAST(cf.cpu_sockets, 2)::NUMERIC
          WHEN i.edition ILIKE '%%Standard%%' THEN
            cf.cpu_sockets::NUMERIC
          ELSE ROUND(cf.total_physical_cores * cf.core_factor, 2)
        END                                             AS current_metric_licences,

        -- Cheapest processor option (informational)
        CASE
          WHEN ROUND(cf.total_physical_cores * cf.core_factor, 2)
               <= LEAST(cf.cpu_sockets, 2)
          THEN 'EE Processor (' || ROUND(cf.total_physical_cores * cf.core_factor,2) || ' licences)'
          ELSE 'SE2 Processor (' || LEAST(cf.cpu_sockets,2) || ' licences)'
        END                                             AS lowest_processor_option

      FROM   %I.oracle_servers     s
      JOIN   %I.oracle_instances   i  ON i.server_id = s.server_id AND i.is_active
      JOIN   cf                       ON cf.server_id = s.server_id
      WHERE  s.is_active = TRUE
    ),

    -- ---- WebLogic rows ----
    wls_rows AS (
      SELECT
        s.server_id,
        s.hostname,
        s.environment::TEXT,
        s.datacenter,
        'oracle_weblogic'::TEXT                         AS product_family,
        d.wls_edition                                   AS product_detail,
        d.wls_version                                   AS product_version,
        cf.cpu_model,
        cf.cpu_sockets,
        cf.cores_per_socket,
        cf.total_physical_cores,
        cf.core_factor,
        cf.virt_type::TEXT,
        cf.is_vmware,

        -- WLS is always processor-licensed; NUP is not available for WLS
        ROUND(cf.total_physical_cores * cf.core_factor, 2)
                                                        AS proc_perpetual_ee,
        NULL::NUMERIC                                   AS proc_perpetual_se2,

        -- WLS has no NUP metric — show NULL
        NULL::NUMERIC                                   AS nup_minimum_ee,
        NULL::NUMERIC                                   AS nup_minimum_se2,

        'processor'::TEXT                               AS current_metric,
        ROUND(cf.total_physical_cores * cf.core_factor, 2)
                                                        AS current_metric_licences,
        'Processor (' || ROUND(cf.total_physical_cores * cf.core_factor, 2) || ' licences)'
                                                        AS lowest_processor_option

      FROM   %I.oracle_servers  s
      JOIN   %I.wls_domains     d   ON d.server_id = s.server_id AND d.is_active
      JOIN   cf                     ON cf.server_id = s.server_id
      WHERE  s.is_active = TRUE
    )

    SELECT
      server_id,
      hostname,
      environment,
      datacenter,
      product_family,
      product_detail,
      product_version,
      cpu_model,
      cpu_sockets,
      cores_per_socket,
      total_physical_cores,
      core_factor,
      virt_type,
      is_vmware,

      -- ---- Processor Perpetual ----
      proc_perpetual_ee                                 AS processor_licences_ee,
      proc_perpetual_se2                                AS processor_licences_se2,

      -- ---- Named User Plus minimums ----
      -- These are the MINIMUM NUP licences Oracle requires per server.
      -- Your actual NUP count must be >= this if any user can access the DB.
      nup_minimum_ee                                    AS nup_minimum_ee,
      nup_minimum_se2                                   AS nup_minimum_se2,

      -- ---- Current metric and requirement ----
      current_metric,
      current_metric_licences,

      -- ---- NUP vs Processor break-even (EE only) ----
      -- If actual_user_count < nup_break_even_ee, NUP may be cheaper.
      -- If actual_user_count >= nup_break_even_ee, Processor is cheaper.
      -- (Assumes list price ratio: 1 EE Processor = ~25× NUP)
      nup_minimum_ee                                    AS nup_break_even_user_count,

      lowest_processor_option

    FROM (
      SELECT * FROM db_rows
      UNION ALL
      SELECT * FROM wls_rows
    ) combined
    ORDER BY product_family, environment, hostname, product_detail;

  $view$,
  p_schema,   -- view schema
  p_schema,   -- oracle_processors
  p_schema,   -- oracle_servers (db_rows)
  p_schema,   -- oracle_instances
  p_schema,   -- oracle_servers (wls_rows)
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
-- INSTALL SERVER COVERAGE VIEW
-- Creates server_csi_coverage in each client schema.
-- Shows every active server with its explicit CSI assignments per product
-- family, how many licences each CSI contributes, and — critically —
-- whether the server has any unmapped products (coverage gaps).
-- This is the primary audit-prep view.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.install_server_coverage_view(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($view$
    CREATE OR REPLACE VIEW %I.server_csi_coverage AS

    WITH latest_proc AS (
      SELECT DISTINCT ON (server_id)
        server_id, cpu_model, cpu_sockets, cores_per_socket,
        total_physical_cores, virt_type, is_vmware
      FROM %I.oracle_processors
      ORDER BY server_id, recorded_at DESC
    ),

    core_factor AS (
      SELECT
        lp.server_id,
        lp.total_physical_cores,
        lp.cpu_sockets,
        lp.cpu_model,
        lp.virt_type,
        lp.is_vmware,
        COALESCE(
          (SELECT cf.core_factor FROM shared.core_factor_table cf
           WHERE  lp.cpu_model ILIKE cf.processor_pattern
             AND  cf.processor_pattern <> 'Unknown' AND cf.is_current = TRUE
           ORDER  BY cf.effective_date DESC LIMIT 1),
          (SELECT cf.core_factor FROM shared.core_factor_table cf
           WHERE  cf.processor_pattern = 'Unknown' LIMIT 1),
          0.5
        ) AS core_factor
      FROM latest_proc lp
    ),

    -- All products running on each server
    server_products AS (
      -- Oracle DB instances
      SELECT s.server_id, s.hostname, s.environment::TEXT, s.datacenter,
             'oracle_database'::TEXT AS product_family,
             i.edition               AS product_detail
      FROM   %I.oracle_servers   s
      JOIN   %I.oracle_instances i ON i.server_id = s.server_id AND i.is_active
      WHERE  s.is_active = TRUE

      UNION ALL

      -- WebLogic domains
      SELECT s.server_id, s.hostname, s.environment::TEXT, s.datacenter,
             'oracle_weblogic'::TEXT AS product_family,
             d.wls_edition           AS product_detail
      FROM   %I.oracle_servers s
      JOIN   %I.wls_domains    d ON d.server_id = s.server_id AND d.is_active
      WHERE  s.is_active = TRUE
    ),

    -- Explicit CSI assignments per server+product
    assignments AS (
      SELECT
        scm.server_id,
        scm.product_family,
        scm.csi_id,
        scm.line_id,
        scm.notes                                    AS assignment_notes,
        scm.effective_date,
        scm.assigned_by,
        cs.csi_number,
        cs.contract_name,
        cs.sharing_policy::TEXT,
        -- Licences this server draws from this CSI:
        -- Use explicit licences_consumed if set, otherwise calculate from topology
        COALESCE(
          scm.licences_consumed,
          -- Calculate based on product family and edition
          (SELECT CASE
             WHEN sp2.product_detail ILIKE '%%Enterprise%%'
               THEN ROUND(cf2.total_physical_cores * cf2.core_factor, 2)
             WHEN sp2.product_detail ILIKE '%%Standard Edition 2%%'
               THEN LEAST(cf2.cpu_sockets, 2)::NUMERIC
             WHEN sp2.product_detail ILIKE '%%Standard%%'
               THEN cf2.cpu_sockets::NUMERIC
             ELSE ROUND(cf2.total_physical_cores * cf2.core_factor, 2)
           END
           FROM   server_products sp2
           JOIN   core_factor     cf2 ON cf2.server_id = sp2.server_id
           WHERE  sp2.server_id = scm.server_id
             AND  sp2.product_family = scm.product_family
           LIMIT 1)
        )                                            AS licences_from_this_csi,
        l.product_name                               AS line_product_name,
        l.unit_price,
        l.total_price                                AS line_total_price,
        l.annual_support_cost                        AS line_annual_support
      FROM   %I.server_csi_map              scm
      JOIN   shared.csi_contracts            cs ON cs.csi_id  = scm.csi_id
      LEFT   JOIN shared.license_entitlement_lines l
                                                 ON l.line_id = scm.line_id
    )

    SELECT
      sp.server_id,
      sp.hostname,
      sp.environment,
      sp.datacenter,
      sp.product_family,
      sp.product_detail,
      cf.cpu_sockets,
      cf.total_physical_cores,
      cf.core_factor,
      cf.virt_type::TEXT                             AS virt_type,
      cf.is_vmware,

      -- Calculated licence requirement for this server/product
      CASE
        WHEN sp.product_detail ILIKE '%%Enterprise%%'
          THEN ROUND(cf.total_physical_cores * cf.core_factor, 2)
        WHEN sp.product_detail ILIKE '%%Standard Edition 2%%'
          THEN LEAST(cf.cpu_sockets, 2)::NUMERIC
        WHEN sp.product_detail ILIKE '%%Standard%%'
          THEN cf.cpu_sockets::NUMERIC
        ELSE ROUND(cf.total_physical_cores * cf.core_factor, 2)
      END                                            AS licences_required,

      -- CSI assignment details — one row per server+product,
      -- with CSI list aggregated
      COUNT(a.csi_id)                                AS assigned_csi_count,
      STRING_AGG(
        a.csi_number || ' — ' || a.contract_name,
        E''\n'' ORDER BY a.csi_number
      )                                              AS assigned_csis,
      STRING_AGG(
        a.csi_number,
        '', '' ORDER BY a.csi_number
      )                                              AS assigned_csi_numbers,
      SUM(a.licences_from_this_csi)                  AS total_licences_assigned,
      STRING_AGG(
        COALESCE(a.line_product_name, ''(all lines)''),
        '', '' ORDER BY a.csi_number
      )                                              AS covered_products,
      SUM(a.line_total_price)                        AS assigned_licence_cost,
      SUM(a.line_annual_support)                     AS assigned_support_cost,

      -- Coverage status — key field for audit prep
      CASE
        WHEN COUNT(a.csi_id) = 0
          THEN ''NO CSI ASSIGNED''
        WHEN SUM(a.licences_from_this_csi) IS NULL
          THEN ''ASSIGNED — QUANTITY UNCONFIRMED''
        WHEN SUM(a.licences_from_this_csi)
             >= CASE
                  WHEN sp.product_detail ILIKE ''%%Enterprise%%''
                    THEN ROUND(cf.total_physical_cores * cf.core_factor, 2)
                  WHEN sp.product_detail ILIKE ''%%Standard Edition 2%%''
                    THEN LEAST(cf.cpu_sockets, 2)::NUMERIC
                  ELSE cf.cpu_sockets::NUMERIC
                END
          THEN ''COVERED''
        ELSE ''UNDER-ASSIGNED''
      END                                            AS coverage_status,

      -- How many more licences are needed from a CSI to fully cover this server
      GREATEST(
        CASE
          WHEN sp.product_detail ILIKE '%%Enterprise%%'
            THEN ROUND(cf.total_physical_cores * cf.core_factor, 2)
          WHEN sp.product_detail ILIKE '%%Standard Edition 2%%'
            THEN LEAST(cf.cpu_sockets, 2)::NUMERIC
          WHEN sp.product_detail ILIKE '%%Standard%%'
            THEN cf.cpu_sockets::NUMERIC
          ELSE ROUND(cf.total_physical_cores * cf.core_factor, 2)
        END - COALESCE(SUM(a.licences_from_this_csi), 0),
        0
      )                                              AS coverage_gap

    FROM   server_products sp
    JOIN   core_factor     cf ON cf.server_id = sp.server_id
    LEFT   JOIN assignments a  ON a.server_id = sp.server_id
                              AND a.product_family = sp.product_family
    GROUP  BY sp.server_id, sp.hostname, sp.environment, sp.datacenter,
              sp.product_family, sp.product_detail,
              cf.cpu_sockets, cf.total_physical_cores, cf.core_factor,
              cf.virt_type, cf.is_vmware
    ORDER  BY
      CASE WHEN COUNT(a.csi_id) = 0 THEN 1 ELSE 2 END,
      sp.environment, sp.hostname, sp.product_family;

  $view$,
  p_schema,   -- view schema
  p_schema,   -- oracle_processors
  p_schema,   -- oracle_servers (db products)
  p_schema,   -- oracle_instances
  p_schema,   -- oracle_servers (wls products)
  p_schema,   -- wls_domains
  p_schema    -- server_csi_map
  );
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
      PERFORM sam_admin.install_license_options_view(v_client.schema_name);
      PERFORM sam_admin.install_server_coverage_view(v_client.schema_name);
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

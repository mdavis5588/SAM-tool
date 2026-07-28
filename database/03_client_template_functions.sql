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
  EXECUTE format('DROP VIEW IF EXISTS %I.license_position CASCADE', p_schema);
  EXECUTE format($view$
    CREATE VIEW %I.license_position AS

    WITH latest_proc AS (
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

    -- Latest named-user-plus count per server (sum across all active instances)
    nup_totals AS (
      SELECT
        s.server_id,
        SUM(COALESCE(n.active_user_count, 0)) AS total_nup_users
      FROM %I.oracle_servers s
      JOIN %I.oracle_instances i ON i.server_id = s.server_id AND i.is_active
      LEFT JOIN LATERAL (
        SELECT active_user_count
        FROM %I.oracle_nup_users nu
        WHERE nu.instance_id = i.instance_id
        ORDER BY snapshot_date DESC, recorded_at DESC LIMIT 1
      ) n ON TRUE
      WHERE s.is_active
      GROUP BY s.server_id
    ),

    -- One row per server+edition (DISTINCT ON deduplicates multiple instances
    -- with the same edition — the licence is per physical server, not per instance)
    db_required AS (
      SELECT DISTINCT ON (s.server_id, i.edition)
        s.server_id, s.hostname, s.environment::TEXT,
        'oracle_database'::TEXT AS product_family,
        i.edition               AS product_detail,
        cf.cpu_sockets, cf.total_physical_cores, cf.cpu_model,
        cf.core_factor, cf.virt_type::TEXT, cf.is_vmware,
        -- NUP minimum floor: 25 per processor-licence for EE, 10 per socket for SE2/SE
        CASE
          WHEN i.edition ILIKE '%%Enterprise%%'
            THEN ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
          WHEN i.edition ILIKE '%%Standard Edition 2%%'
            THEN (LEAST(cf.cpu_sockets, 2) * 10)::NUMERIC
          WHEN i.edition ILIKE '%%Standard%%'
            THEN (cf.cpu_sockets * 10)::NUMERIC
          ELSE ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
        END AS nup_minimum,
        COALESCE(nt.total_nup_users, 0)::NUMERIC AS nup_active_users,
        COALESCE(s.licence_metric_override, 'processor_perpetual')::TEXT AS licence_metric,
        CASE
          WHEN COALESCE(s.licence_metric_override, 'processor_perpetual') = 'named_user_plus'
            THEN GREATEST(
              COALESCE(nt.total_nup_users, 0)::NUMERIC,
              CASE
                WHEN i.edition ILIKE '%%Enterprise%%'
                  THEN ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
                WHEN i.edition ILIKE '%%Standard Edition 2%%'
                  THEN (LEAST(cf.cpu_sockets, 2) * 10)::NUMERIC
                WHEN i.edition ILIKE '%%Standard%%'
                  THEN (cf.cpu_sockets * 10)::NUMERIC
                ELSE ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
              END
            )
          WHEN i.edition ILIKE '%%Enterprise%%'         THEN ROUND(cf.total_physical_cores * cf.core_factor, 2)
          WHEN i.edition ILIKE '%%Standard Edition 2%%' THEN LEAST(cf.cpu_sockets, 2)::NUMERIC
          WHEN i.edition ILIKE '%%Standard%%'           THEN cf.cpu_sockets::NUMERIC
          ELSE ROUND(cf.total_physical_cores * cf.core_factor, 2)
        END AS licences_required
      FROM %I.oracle_servers s
      JOIN %I.oracle_instances i ON i.server_id = s.server_id AND i.is_active
      JOIN core_factor cf        ON cf.server_id = s.server_id
      LEFT JOIN nup_totals nt    ON nt.server_id = s.server_id
      WHERE s.is_active = TRUE
      ORDER BY s.server_id, i.edition
    ),

    wls_required AS (
      SELECT
        s.server_id, s.hostname, s.environment::TEXT,
        'oracle_weblogic'::TEXT AS product_family,
        d.wls_edition           AS product_detail,
        cf.cpu_sockets, cf.total_physical_cores, cf.cpu_model,
        cf.core_factor, cf.virt_type::TEXT, cf.is_vmware,
        NULL::NUMERIC           AS nup_minimum,
        NULL::NUMERIC           AS nup_active_users,
        'processor_perpetual'::TEXT AS licence_metric,
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

    -- One row per server+licensed option (EE only — options don't apply to SE/SE2).
    -- Licence requirement = same cores × core_factor metric as base EE.
    option_required AS (
      SELECT DISTINCT ON (s.server_id, olo.display_name)
        s.server_id, s.hostname, s.environment::TEXT,
        'oracle_database'::TEXT  AS product_family,
        olo.display_name         AS product_detail,
        cf.cpu_sockets, cf.total_physical_cores, cf.cpu_model,
        cf.core_factor, cf.virt_type::TEXT, cf.is_vmware,
        NULL::NUMERIC            AS nup_minimum,
        NULL::NUMERIC            AS nup_active_users,
        'processor_perpetual'::TEXT AS licence_metric,
        ROUND(cf.total_physical_cores * cf.core_factor, 2) AS licences_required
      FROM %I.oracle_servers s
      JOIN %I.oracle_instances  i   ON i.server_id   = s.server_id
                                    AND i.is_active
                                    AND i.edition ILIKE '%%Enterprise%%'
      JOIN %I.oracle_options    opt ON opt.instance_id = i.instance_id
                                    AND opt.status = 'TRUE'
      JOIN shared.oracle_licensed_options olo ON olo.option_name = opt.option_name
                                              AND olo.is_active
      JOIN core_factor cf ON cf.server_id = s.server_id
      WHERE s.is_active
      ORDER BY s.server_id, olo.display_name
    ),

    all_required AS (
      SELECT * FROM db_required
      UNION ALL SELECT * FROM wls_required
      UNION ALL SELECT * FROM option_required
    ),

    -- Per-line CSI coverage: sum licences_consumed from assignments that match
    -- this server + product_family + product_detail exactly.
    line_csi_coverage AS (
      SELECT
        scm.server_id,
        scm.product_family,
        COALESCE(scm.product_detail, '') AS product_detail_key,
        COALESCE(SUM(scm.licences_consumed), 0) AS total_licensed,
        STRING_AGG(
          cs.csi_number || ' (' || cs.contract_name || ')',
          ', ' ORDER BY cs.csi_number
        ) AS assigned_csi_numbers,
        COUNT(scm.map_id) AS csi_assignment_count
      FROM %I.server_csi_map scm
      JOIN shared.csi_contracts cs ON cs.csi_id = scm.csi_id
      GROUP BY scm.server_id, scm.product_family, COALESCE(scm.product_detail, '')
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
      ar.licence_metric,
      ar.nup_minimum,
      ar.nup_active_users,
      ar.licences_required,
      COALESCE(lcc.assigned_csi_numbers, '')       AS assigned_csi_numbers,
      COALESCE(lcc.csi_assignment_count, 0)        AS csi_assignment_count,
      COALESCE(lcc.csi_assignment_count, 0) > 0   AS has_explicit_csi,
      COALESCE(lcc.total_licensed, 0)              AS total_licensed,
      COALESCE(lcc.total_licensed, 0)
        - ar.licences_required                     AS licence_surplus_deficit,
      CASE
        WHEN COALESCE(lcc.total_licensed, 0) >= ar.licences_required
        THEN 'compliant'
        ELSE 'under_licensed'
      END                                          AS compliance_status

    FROM   all_required ar
    LEFT   JOIN line_csi_coverage lcc
           ON  lcc.server_id          = ar.server_id
           AND lcc.product_family     = ar.product_family
           AND lcc.product_detail_key = COALESCE(ar.product_detail, '')
    ORDER  BY ar.product_family, ar.environment, ar.hostname, ar.product_detail;

  $view$,
  p_schema,   -- 1  view schema
  p_schema,   -- 2  oracle_processors
  p_schema,   -- 3  oracle_servers  (nup_totals)
  p_schema,   -- 4  oracle_instances (nup_totals)
  p_schema,   -- 5  oracle_nup_users (nup_totals)
  p_schema,   -- 6  oracle_servers  (db_required)
  p_schema,   -- 7  oracle_instances (db_required)
  p_schema,   -- 8  oracle_servers  (wls_required)
  p_schema,   -- 9  wls_domains
  p_schema,   -- 10 oracle_servers  (option_required)
  p_schema,   -- 11 oracle_instances (option_required)
  p_schema,   -- 12 oracle_options
  p_schema    -- 13 server_csi_map
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
  EXECUTE format('DROP VIEW IF EXISTS %I.license_metric_comparison CASCADE', p_schema);
  EXECUTE format($view$
    CREATE VIEW %I.license_metric_comparison AS

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
        (p_payload->>'environment')::environment_type,
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
        (COALESCE(p_payload->>'virt_type','unknown'))::virt_type,
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
  p_schema, p_schema, p_schema, p_schema, p_schema);

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
        (p_payload->>'environment')::environment_type,
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
          (COALESCE(p_payload->>'virt_type','unknown'))::virt_type,
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
  p_schema, p_schema, p_schema,
  p_schema, p_schema, p_schema);

END;
$$;

-- ---------------------------------------------------------------------------
-- INSTALL SERVER COVERAGE VIEW
-- Creates server_csi_coverage in each client schema.
-- Shows every active server with its explicit CSI assignments per product
-- family, how many licences each CSI contributes, and whether the server
-- has any unmapped products (coverage gaps).
-- This is the primary audit-prep view.
--
-- Uses variable concatenation instead of format() to avoid dollar-quote
-- conflicts with string literals inside CASE expressions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.install_server_coverage_view(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_sql TEXT;
BEGIN
  EXECUTE 'DROP VIEW IF EXISTS ' || quote_ident(p_schema) || '.server_csi_coverage CASCADE';
  v_sql :=
    'CREATE VIEW ' || quote_ident(p_schema) || '.server_csi_coverage AS

    WITH latest_proc AS (
      SELECT DISTINCT ON (server_id)
        server_id, cpu_model, cpu_sockets, cores_per_socket,
        total_physical_cores, virt_type, is_vmware
      FROM ' || quote_ident(p_schema) || '.oracle_processors
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
             AND  cf.processor_pattern <> ''Unknown'' AND cf.is_current = TRUE
           ORDER  BY cf.effective_date DESC LIMIT 1),
          (SELECT cf.core_factor FROM shared.core_factor_table cf
           WHERE  cf.processor_pattern = ''Unknown'' LIMIT 1),
          0.5
        ) AS core_factor
      FROM latest_proc lp
    ),

    server_products AS (
      SELECT s.server_id, s.hostname, s.environment::TEXT, s.datacenter,
             ''oracle_database''::TEXT AS product_family,
             i.edition               AS product_detail
      FROM   ' || quote_ident(p_schema) || '.oracle_servers   s
      JOIN   ' || quote_ident(p_schema) || '.oracle_instances i
             ON i.server_id = s.server_id AND i.is_active
      WHERE  s.is_active = TRUE

      UNION ALL

      SELECT s.server_id, s.hostname, s.environment::TEXT, s.datacenter,
             ''oracle_weblogic''::TEXT AS product_family,
             d.wls_edition           AS product_detail
      FROM   ' || quote_ident(p_schema) || '.oracle_servers s
      JOIN   ' || quote_ident(p_schema) || '.wls_domains    d
             ON d.server_id = s.server_id AND d.is_active
      WHERE  s.is_active = TRUE
    ),

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
        COALESCE(
          scm.licences_consumed,
          (SELECT CASE
             WHEN sp2.product_detail ILIKE ''%Enterprise%''
               THEN ROUND(cf2.total_physical_cores * cf2.core_factor, 2)
             WHEN sp2.product_detail ILIKE ''%Standard Edition 2%''
               THEN LEAST(cf2.cpu_sockets, 2)::NUMERIC
             WHEN sp2.product_detail ILIKE ''%Standard%''
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
      FROM   ' || quote_ident(p_schema) || '.server_csi_map scm
      JOIN   shared.csi_contracts                     cs ON cs.csi_id  = scm.csi_id
      LEFT   JOIN shared.license_entitlement_lines    l  ON l.line_id  = scm.line_id
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

      CASE
        WHEN sp.product_detail ILIKE ''%Enterprise%''
          THEN ROUND(cf.total_physical_cores * cf.core_factor, 2)
        WHEN sp.product_detail ILIKE ''%Standard Edition 2%''
          THEN LEAST(cf.cpu_sockets, 2)::NUMERIC
        WHEN sp.product_detail ILIKE ''%Standard%''
          THEN cf.cpu_sockets::NUMERIC
        ELSE ROUND(cf.total_physical_cores * cf.core_factor, 2)
      END                                            AS licences_required,

      COUNT(a.csi_id)                                AS assigned_csi_count,
      STRING_AGG(
        a.csi_number || '' — '' || a.contract_name,
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

      CASE
        WHEN COUNT(a.csi_id) = 0
          THEN ''NO CSI ASSIGNED''
        WHEN SUM(a.licences_from_this_csi) IS NULL
          THEN ''ASSIGNED — QUANTITY UNCONFIRMED''
        WHEN SUM(a.licences_from_this_csi) >=
          CASE
            WHEN sp.product_detail ILIKE ''%Enterprise%''
              THEN ROUND(cf.total_physical_cores * cf.core_factor, 2)
            WHEN sp.product_detail ILIKE ''%Standard Edition 2%''
              THEN LEAST(cf.cpu_sockets, 2)::NUMERIC
            ELSE cf.cpu_sockets::NUMERIC
          END
          THEN ''COVERED''
        ELSE ''UNDER-ASSIGNED''
      END                                            AS coverage_status,

      GREATEST(
        CASE
          WHEN sp.product_detail ILIKE ''%Enterprise%''
            THEN ROUND(cf.total_physical_cores * cf.core_factor, 2)
          WHEN sp.product_detail ILIKE ''%Standard Edition 2%''
            THEN LEAST(cf.cpu_sockets, 2)::NUMERIC
          WHEN sp.product_detail ILIKE ''%Standard%''
            THEN cf.cpu_sockets::NUMERIC
          ELSE ROUND(cf.total_physical_cores * cf.core_factor, 2)
        END - COALESCE(SUM(a.licences_from_this_csi), 0),
        0
      )                                              AS coverage_gap

    FROM   server_products sp
    JOIN   core_factor     cf ON cf.server_id = sp.server_id
    LEFT   JOIN assignments a  ON a.server_id     = sp.server_id
                              AND a.product_family = sp.product_family
    GROUP  BY sp.server_id, sp.hostname, sp.environment, sp.datacenter,
              sp.product_family, sp.product_detail,
              cf.cpu_sockets, cf.total_physical_cores, cf.core_factor,
              cf.virt_type, cf.is_vmware
    ORDER  BY
      CASE WHEN COUNT(a.csi_id) = 0 THEN 1 ELSE 2 END,
      sp.environment, sp.hostname, sp.product_family';

  EXECUTE v_sql;
END;
$$;

-- ---------------------------------------------------------------------------
-- INSTALL CHANGELOG OBJECTS
-- Creates the trigger functions and triggers that detect licence-relevant
-- changes between discovery runs and write them to discovery_changelog.
--
-- Monitored events and their severity:
--
--  HIGH (licence-impacting — requires immediate review):
--    - New oracle_option appearing on an instance (Diagnostic Pack, Tuning Pack,
--      Partitioning, Advanced Security, etc.)
--    - Oracle instance edition change (SE2 → EE is a major cost increase)
--    - Processor core count or socket count increase
--    - New WLS installed product (SOA Suite, Coherence, OAM etc.)
--    - New WLS domain on a server not previously running WLS
--
--  MEDIUM (notable — review recommended):
--    - New Oracle instance (SID) appearing on a known server
--    - Oracle version upgrade
--    - New server discovered for the first time
--    - WLS version upgrade
--
--  INFO (informational):
--    - Oracle option status change (e.g. VALID → OPTION OFF)
--    - Processor model change (unlikely but tracked for core factor changes)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.install_changelog_objects(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN

  -- -------------------------------------------------------------------------
  -- TRIGGER FUNCTION: log_option_change
  -- Fires on INSERT/UPDATE to oracle_options.
  -- New options are HIGH severity — they indicate a licensed feature was
  -- enabled since the last discovery run.
  -- -------------------------------------------------------------------------
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.log_option_change()
    RETURNS TRIGGER LANGUAGE plpgsql AS $body$
    DECLARE
      v_hostname  TEXT;
      v_sid       TEXT;
      v_server_id INTEGER;
      v_run_id    TEXT;
      v_severity  TEXT;
      v_impact    TEXT;
    BEGIN
      -- Resolve hostname and SID for the affected instance
      SELECT s.hostname, i.oracle_sid, s.server_id
      INTO   v_hostname, v_sid, v_server_id
      FROM   %I.oracle_instances i
      JOIN   %I.oracle_servers   s ON s.server_id = i.server_id
      WHERE  i.instance_id = NEW.instance_id;

      v_run_id := NEW.discovery_run_id;

      -- Classify severity by option name
      v_severity := CASE
        WHEN NEW.option_name ILIKE ANY (ARRAY[
          '%%Diagnostic Pack%%', '%%Tuning Pack%%', '%%Partitioning%%',
          '%%Advanced Security%%', '%%Label Security%%', '%%Database Vault%%',
          '%%Active Data Guard%%', '%%GoldenGate%%', '%%RAC%%',
          '%%Real Application Clusters%%', '%%Multitenant%%',
          '%%In-Memory%%', '%%Spatial%%', '%%Text%%'
        ]) THEN 'HIGH'
        ELSE 'MEDIUM'
      END;

      v_impact := CASE
        WHEN NEW.option_name ILIKE '%%Diagnostic Pack%%'
          THEN 'Diagnostic Pack requires a separate processor licence (Oracle Technology Price List)'
        WHEN NEW.option_name ILIKE '%%Tuning Pack%%'
          THEN 'Tuning Pack requires a separate processor licence and also requires Diagnostic Pack'
        WHEN NEW.option_name ILIKE '%%Partitioning%%'
          THEN 'Partitioning is a separately-licensed EE option'
        WHEN NEW.option_name ILIKE '%%Advanced Security%%'
          THEN 'Advanced Security (TDE/network encryption) requires a separate processor licence'
        WHEN NEW.option_name ILIKE '%%Active Data Guard%%'
          THEN 'Active Data Guard requires a separate processor licence per standby'
        WHEN NEW.option_name ILIKE '%%Multitenant%%'
          THEN 'Multitenant (>1 PDB) requires a separate processor licence in 12c+'
        WHEN NEW.option_name ILIKE '%%RAC%%' OR NEW.option_name ILIKE '%%Real Application Clusters%%'
          THEN 'RAC requires processor licences on ALL nodes in the cluster'
        ELSE 'Review Oracle Technology Price List for this option'
      END;

      IF TG_OP = 'INSERT' THEN
        INSERT INTO %I.discovery_changelog
          (discovery_run_id, server_id, hostname, change_category, change_type,
           severity, object_name, field_changed, old_value, new_value, licence_impact)
        VALUES (
          v_run_id, v_server_id, v_hostname,
          'oracle_option', 'NEW',
          v_severity,
          v_sid || ' → ' || NEW.option_name,
          NULL, NULL, NEW.status,
          v_impact
        );

      ELSIF TG_OP = 'UPDATE' AND OLD.status <> NEW.status THEN
        INSERT INTO %I.discovery_changelog
          (discovery_run_id, server_id, hostname, change_category, change_type,
           severity, object_name, field_changed, old_value, new_value, licence_impact)
        VALUES (
          v_run_id, v_server_id, v_hostname,
          'oracle_option', 'CHANGED',
          'INFO',
          v_sid || ' → ' || NEW.option_name,
          'status', OLD.status, NEW.status,
          'Option status changed — verify whether usage has started or stopped'
        );
      END IF;

      RETURN NEW;
    END;
    $body$;
  $fn$, p_schema, p_schema, p_schema, p_schema, p_schema);

  -- Create trigger on oracle_options
  EXECUTE format('DROP TRIGGER IF EXISTS trg_log_option_change ON %I.oracle_options',
    p_schema);
  EXECUTE format('CREATE TRIGGER trg_log_option_change
      AFTER INSERT OR UPDATE ON %I.oracle_options
      FOR EACH ROW EXECUTE FUNCTION %I.log_option_change()',
    p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- TRIGGER FUNCTION: log_instance_change
  -- Fires on INSERT/UPDATE to oracle_instances.
  -- New instances are MEDIUM; edition changes are HIGH.
  -- -------------------------------------------------------------------------
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.log_instance_change()
    RETURNS TRIGGER LANGUAGE plpgsql AS $body$
    DECLARE
      v_hostname TEXT;
    BEGIN
      SELECT hostname INTO v_hostname
      FROM   %I.oracle_servers WHERE server_id = NEW.server_id;

      IF TG_OP = 'INSERT' THEN
        INSERT INTO %I.discovery_changelog
          (discovery_run_id, server_id, hostname, change_category, change_type,
           severity, object_name, new_value, licence_impact)
        VALUES (
          NEW.discovery_run_id, NEW.server_id, v_hostname,
          'oracle_instance', 'NEW',
          'MEDIUM',
          NEW.oracle_sid,
          NEW.edition || ' ' || COALESCE(NEW.db_version, ''),
          'New Oracle instance detected — verify licence coverage for this SID'
        );

      ELSIF TG_OP = 'UPDATE' THEN
        -- Edition change — HIGH severity, major cost implication
        IF OLD.edition IS DISTINCT FROM NEW.edition THEN
          INSERT INTO %I.discovery_changelog
            (discovery_run_id, server_id, hostname, change_category, change_type,
             severity, object_name, field_changed, old_value, new_value, licence_impact)
          VALUES (
            NEW.discovery_run_id, NEW.server_id, v_hostname,
            'oracle_instance', 'CHANGED',
            'HIGH',
            NEW.oracle_sid, 'edition', OLD.edition, NEW.edition,
            'Edition change may significantly alter licence requirements — recalculate immediately'
          );
        END IF;

        -- Version upgrade — MEDIUM, may change available options
        IF OLD.db_version IS DISTINCT FROM NEW.db_version THEN
          INSERT INTO %I.discovery_changelog
            (discovery_run_id, server_id, hostname, change_category, change_type,
             severity, object_name, field_changed, old_value, new_value, licence_impact)
          VALUES (
            NEW.discovery_run_id, NEW.server_id, v_hostname,
            'oracle_instance', 'CHANGED',
            'MEDIUM',
            NEW.oracle_sid, 'db_version', OLD.db_version, NEW.db_version,
            'Version upgrade — re-run options discovery to detect any newly-available licensed features'
          );
        END IF;
      END IF;

      RETURN NEW;
    END;
    $body$;
  $fn$, p_schema, p_schema, p_schema, p_schema, p_schema);

  EXECUTE format('DROP TRIGGER IF EXISTS trg_log_instance_change ON %I.oracle_instances',
    p_schema);
  EXECUTE format('CREATE TRIGGER trg_log_instance_change
      AFTER INSERT OR UPDATE ON %I.oracle_instances
      FOR EACH ROW EXECUTE FUNCTION %I.log_instance_change()',
    p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- TRIGGER FUNCTION: log_processor_change
  -- Fires on INSERT to oracle_processors (each discovery inserts a new row).
  -- Compares against the previous snapshot for the same server.
  -- Core count increases are HIGH — they change the licence calculation.
  -- -------------------------------------------------------------------------
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.log_processor_change()
    RETURNS TRIGGER LANGUAGE plpgsql AS $body$
    DECLARE
      v_hostname TEXT;
      v_prev     RECORD;
    BEGIN
      SELECT hostname INTO v_hostname
      FROM   %I.oracle_servers WHERE server_id = NEW.server_id;

      -- Get the most recent PREVIOUS snapshot (exclude the row just inserted)
      SELECT * INTO v_prev
      FROM   %I.oracle_processors
      WHERE  server_id = NEW.server_id
        AND  proc_id <> NEW.proc_id
      ORDER  BY recorded_at DESC
      LIMIT  1;

      IF NOT FOUND THEN
        -- First ever discovery for this server
        INSERT INTO %I.discovery_changelog
          (discovery_run_id, server_id, hostname, change_category, change_type,
           severity, object_name, new_value, licence_impact)
        VALUES (
          NEW.discovery_run_id, NEW.server_id, v_hostname,
          'processor', 'NEW',
          'MEDIUM',
          v_hostname,
          NEW.cpu_sockets || ' sockets, ' || NEW.total_physical_cores || ' cores (' || NEW.cpu_model || ')',
          'New server in scope — assign to a CSI contract and verify licence coverage'
        );
        RETURN NEW;
      END IF;

      -- Socket count increase — HIGH
      IF NEW.cpu_sockets > v_prev.cpu_sockets THEN
        INSERT INTO %I.discovery_changelog
          (discovery_run_id, server_id, hostname, change_category, change_type,
           severity, object_name, field_changed, old_value, new_value, licence_impact)
        VALUES (
          NEW.discovery_run_id, NEW.server_id, v_hostname,
          'processor', 'CHANGED', 'HIGH', v_hostname,
          'cpu_sockets',
          v_prev.cpu_sockets::TEXT, NEW.cpu_sockets::TEXT,
          'Socket count increased — recalculate processor licence requirement immediately'
        );
      END IF;

      -- Core count increase — HIGH
      IF NEW.total_physical_cores > v_prev.total_physical_cores THEN
        INSERT INTO %I.discovery_changelog
          (discovery_run_id, server_id, hostname, change_category, change_type,
           severity, object_name, field_changed, old_value, new_value, licence_impact)
        VALUES (
          NEW.discovery_run_id, NEW.server_id, v_hostname,
          'processor', 'CHANGED', 'HIGH', v_hostname,
          'total_physical_cores',
          v_prev.total_physical_cores::TEXT, NEW.total_physical_cores::TEXT,
          'Core count increased — processor licence requirement has increased. Update server_csi_map.'
        );
      END IF;

      -- CPU model change — MEDIUM (may change core factor)
      IF NEW.cpu_model IS DISTINCT FROM v_prev.cpu_model THEN
        INSERT INTO %I.discovery_changelog
          (discovery_run_id, server_id, hostname, change_category, change_type,
           severity, object_name, field_changed, old_value, new_value, licence_impact)
        VALUES (
          NEW.discovery_run_id, NEW.server_id, v_hostname,
          'processor', 'CHANGED', 'MEDIUM', v_hostname,
          'cpu_model',
          v_prev.cpu_model, NEW.cpu_model,
          'CPU model changed — verify core factor in shared.core_factor_table is still correct'
        );
      END IF;

      RETURN NEW;
    END;
    $body$;
  $fn$, p_schema, p_schema, p_schema, p_schema, p_schema, p_schema, p_schema);

  EXECUTE format('DROP TRIGGER IF EXISTS trg_log_processor_change ON %I.oracle_processors',
    p_schema);
  EXECUTE format('CREATE TRIGGER trg_log_processor_change
      AFTER INSERT ON %I.oracle_processors
      FOR EACH ROW EXECUTE FUNCTION %I.log_processor_change()',
    p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- TRIGGER FUNCTION: log_wls_product_change
  -- Fires on INSERT to wls_installed_products.
  -- New middleware products (SOA, Coherence, OAM) are HIGH — each needs
  -- its own processor licence.
  -- -------------------------------------------------------------------------
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.log_wls_product_change()
    RETURNS TRIGGER LANGUAGE plpgsql AS $body$
    DECLARE
      v_hostname  TEXT;
      v_server_id INTEGER;
      v_domain    TEXT;
      v_severity  TEXT;
      v_impact    TEXT;
    BEGIN
      SELECT s.hostname, s.server_id, d.domain_name
      INTO   v_hostname, v_server_id, v_domain
      FROM   %I.wls_domains  d
      JOIN   %I.oracle_servers s ON s.server_id = d.server_id
      WHERE  d.domain_id = NEW.domain_id;

      v_severity := CASE
        WHEN NEW.product_name ILIKE ANY (ARRAY[
          '%%SOA Suite%%', '%%Service Bus%%', '%%Coherence%%',
          '%%Access Manager%%', '%%Identity Governance%%',
          '%%WebCenter%%', '%%BPM%%', '%%OSB%%'
        ]) THEN 'HIGH'
        ELSE 'MEDIUM'
      END;

      v_impact := CASE
        WHEN NEW.product_name ILIKE '%%SOA Suite%%'
          THEN 'Oracle SOA Suite requires a separate processor licence'
        WHEN NEW.product_name ILIKE '%%Service Bus%%' OR NEW.product_name ILIKE '%%OSB%%'
          THEN 'Oracle Service Bus requires a separate processor licence'
        WHEN NEW.product_name ILIKE '%%Coherence%%'
          THEN 'Oracle Coherence requires a separate processor licence when used independently of WLS Suite'
        WHEN NEW.product_name ILIKE '%%Access Manager%%'
          THEN 'Oracle Access Manager requires a separate processor licence'
        WHEN NEW.product_name ILIKE '%%Identity Governance%%'
          THEN 'Oracle Identity Governance requires a separate processor licence'
        ELSE 'New middleware product detected — review Oracle Technology Price List for licence requirements'
      END;

      INSERT INTO %I.discovery_changelog
        (discovery_run_id, server_id, hostname, change_category, change_type,
         severity, object_name, new_value, licence_impact)
      VALUES (
        NEW.discovery_run_id, v_server_id, v_hostname,
        'wls_product', 'NEW',
        v_severity,
        v_domain || ' → ' || NEW.product_name,
        COALESCE(NEW.product_version, 'unknown version'),
        v_impact
      );

      RETURN NEW;
    END;
    $body$;
  $fn$, p_schema, p_schema, p_schema, p_schema);

  EXECUTE format('DROP TRIGGER IF EXISTS trg_log_wls_product_change ON %I.wls_installed_products',
    p_schema);
  EXECUTE format('CREATE TRIGGER trg_log_wls_product_change
      AFTER INSERT ON %I.wls_installed_products
      FOR EACH ROW EXECUTE FUNCTION %I.log_wls_product_change()',
    p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- TRIGGER FUNCTION: log_wls_domain_change
  -- New WLS domain on a server = MEDIUM (or HIGH if it's a new server).
  -- Edition change on an existing domain = HIGH.
  -- -------------------------------------------------------------------------
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.log_wls_domain_change()
    RETURNS TRIGGER LANGUAGE plpgsql AS $body$
    DECLARE
      v_hostname TEXT;
    BEGIN
      SELECT hostname INTO v_hostname
      FROM   %I.oracle_servers WHERE server_id = NEW.server_id;

      IF TG_OP = 'INSERT' THEN
        INSERT INTO %I.discovery_changelog
          (discovery_run_id, server_id, hostname, change_category, change_type,
           severity, object_name, new_value, licence_impact)
        VALUES (
          NEW.discovery_run_id, NEW.server_id, v_hostname,
          'wls_domain', 'NEW',
          'MEDIUM',
          NEW.domain_name,
          COALESCE(NEW.wls_edition, 'unknown edition') || ' ' || COALESCE(NEW.wls_version, ''),
          'New WLS domain detected — verify processor licence coverage and check for installed products'
        );

      ELSIF TG_OP = 'UPDATE' AND OLD.wls_edition IS DISTINCT FROM NEW.wls_edition THEN
        INSERT INTO %I.discovery_changelog
          (discovery_run_id, server_id, hostname, change_category, change_type,
           severity, object_name, field_changed, old_value, new_value, licence_impact)
        VALUES (
          NEW.discovery_run_id, NEW.server_id, v_hostname,
          'wls_domain', 'CHANGED',
          'HIGH',
          NEW.domain_name, 'wls_edition', OLD.wls_edition, NEW.wls_edition,
          'WLS edition change — recalculate licence requirement and update CSI assignment'
        );
      END IF;

      RETURN NEW;
    END;
    $body$;
  $fn$, p_schema, p_schema, p_schema, p_schema);

  EXECUTE format('DROP TRIGGER IF EXISTS trg_log_wls_domain_change ON %I.wls_domains',
    p_schema);
  EXECUTE format('CREATE TRIGGER trg_log_wls_domain_change
      AFTER INSERT OR UPDATE ON %I.wls_domains
      FOR EACH ROW EXECUTE FUNCTION %I.log_wls_domain_change()',
    p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- CHANGELOG SUMMARY VIEW
  -- Unacknowledged changes grouped for the Power BI dashboard banner.
  -- -------------------------------------------------------------------------
  EXECUTE format('DROP VIEW IF EXISTS %I.changelog_summary CASCADE', p_schema);
  EXECUTE format($view$
    CREATE VIEW %I.changelog_summary AS
    SELECT
      change_id,
      detected_at,
      discovery_run_id,
      server_id,
      hostname,
      change_category,
      change_type,
      severity,
      object_name,
      field_changed,
      old_value,
      new_value,
      licence_impact,
      acknowledged,
      acknowledged_by,
      acknowledged_at,
      notes,
      -- Age of the change
      EXTRACT(EPOCH FROM (NOW() - detected_at)) / 3600  AS hours_since_detected,
      -- Flag if unacknowledged HIGH changes are more than 48 hours old
      CASE
        WHEN NOT acknowledged
          AND severity = 'HIGH'
          AND detected_at < NOW() - INTERVAL '48 hours'
        THEN TRUE ELSE FALSE
      END                                               AS overdue
    FROM %I.discovery_changelog
    ORDER BY
      CASE severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
      detected_at DESC
  $view$, p_schema, p_schema);

  -- Install the auto-snapshot trigger for feature activation events.
  -- Defined in migration 17_auto_snapshots.sql; guard against running before
  -- that migration has been applied.
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'sam_admin'
      AND p.proname = 'install_feature_activation_trigger'
  ) THEN
    PERFORM sam_admin.install_feature_activation_trigger(p_schema);
  END IF;

END;
$$;
-- ---------------------------------------------------------------------------
-- INSTALL EXTENDED VIEWS
-- Creates views and upsert functions for:
--   - Java SE licence position
--   - MySQL Enterprise licence position
--   - Named User Plus (NUP) coverage vs minimum requirements
--   - OCI instance licence position (BYOL vs licence-included)
--   - Extended Oracle upsert (RAC nodes, PDBs, NUP users, v$option extras)
--   - Java discovery upsert
--   - MySQL discovery upsert
--   - OCI discovery upsert
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.install_extended_views(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN

  -- -------------------------------------------------------------------------
  -- Add exemption columns to java_installations if this is a migration run
  -- (idempotent — IF NOT EXISTS guards make it safe to re-run)
  -- -------------------------------------------------------------------------
  EXECUTE format($ddl$
    ALTER TABLE %I.java_installations
      ADD COLUMN IF NOT EXISTS licence_exempt  BOOLEAN NOT NULL DEFAULT FALSE,
      ADD COLUMN IF NOT EXISTS exempt_reason   TEXT
        CHECK (exempt_reason IN (
          'oracle_oem', 'oracle_database_jvm', 'oracle_weblogic',
          'oracle_fusion_middleware', 'oracle_forms_reports', 'custom'
        )),
      ADD COLUMN IF NOT EXISTS exempt_notes    TEXT,
      ADD COLUMN IF NOT EXISTS exempt_set_by   TEXT,
      ADD COLUMN IF NOT EXISTS exempt_set_at   TIMESTAMPTZ
  $ddl$, p_schema);

  -- -------------------------------------------------------------------------
  -- JAVA LICENCE POSITION VIEW
  -- Shows every discovered Java installation with its licence requirement.
  -- Exempt installations are included but flagged; use WHERE licence_exempt = FALSE
  -- to restrict to installs that require a licence.
  -- -------------------------------------------------------------------------
  EXECUTE format('DROP VIEW IF EXISTS %I.java_licence_position CASCADE', p_schema);
  EXECUTE format($view$
    CREATE VIEW %I.java_licence_position AS
    SELECT
      s.server_id,
      s.hostname,
      s.environment::TEXT,
      s.datacenter,
      j.java_id,
      j.java_home,
      j.java_vendor,
      j.java_version,
      j.java_major_version,
      j.java_edition,
      j.is_oracle_jdk,
      j.requires_licence,
      j.licence_metric,
      j.licence_exempt,
      j.exempt_reason,
      j.exempt_notes,
      j.exempt_set_by,
      j.exempt_set_at,
      j.first_seen,
      j.last_seen,
      COALESCE(je.notes, 'Unknown edition — manual review required') AS edition_notes,
      CASE
        WHEN j.licence_exempt THEN 'exempt'
        WHEN j.requires_licence THEN 'licence_required'
        ELSE 'no_licence_required'
      END AS licence_status
    FROM   %I.java_installations j
    JOIN   %I.oracle_servers      s  ON s.server_id = j.server_id AND s.is_active
    LEFT   JOIN shared.java_license_editions je
           ON  je.edition_name = j.java_edition
    ORDER  BY j.licence_exempt ASC, j.requires_licence DESC,
              s.hostname, j.java_major_version DESC
  $view$, p_schema, p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- MYSQL LICENCE POSITION VIEW
  -- Shows every discovered MySQL installation with its licence requirement.
  -- -------------------------------------------------------------------------
  EXECUTE format('DROP VIEW IF EXISTS %I.mysql_licence_position CASCADE', p_schema);
  EXECUTE format($view$
    CREATE VIEW %I.mysql_licence_position AS
    SELECT
      s.server_id,
      s.hostname,
      s.environment::TEXT,
      s.datacenter,
      m.mysql_id,
      m.mysql_version,
      m.mysql_edition,
      m.install_path,
      m.port,
      m.is_enterprise,
      m.requires_licence,
      m.first_seen,
      m.last_seen,
      COALESCE(me.licence_metric, 'server') AS licence_metric,
      COALESCE(me.notes, 'Unknown edition') AS edition_notes
    FROM   %I.mysql_installations m
    JOIN   %I.oracle_servers       s  ON s.server_id = m.server_id AND s.is_active
    LEFT   JOIN shared.mysql_license_editions me
           ON  me.edition_name = m.mysql_edition
    ORDER  BY m.requires_licence DESC, s.hostname
  $view$, p_schema, p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- NUP COVERAGE VIEW
  -- Compares the most recent actual user count per instance against the
  -- NUP minimum floor (25 NUP per EE processor licence, 10 NUP per SE2).
  -- -------------------------------------------------------------------------
  EXECUTE format('DROP VIEW IF EXISTS %I.nup_coverage CASCADE', p_schema);
  EXECUTE format($view$
    CREATE VIEW %I.nup_coverage AS
    WITH latest_proc AS (
      SELECT DISTINCT ON (server_id)
        server_id, cpu_model, cpu_sockets, total_physical_cores
      FROM %I.oracle_processors
      ORDER BY server_id, recorded_at DESC
    ),
    core_factor AS (
      SELECT
        lp.server_id,
        lp.total_physical_cores,
        lp.cpu_sockets,
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
    latest_nup AS (
      SELECT DISTINCT ON (instance_id)
        instance_id, active_user_count, total_user_count,
        locked_user_count, snapshot_date
      FROM %I.oracle_nup_users
      ORDER BY instance_id, snapshot_date DESC, recorded_at DESC
    )
    SELECT
      s.server_id,
      s.hostname,
      s.environment::TEXT,
      i.instance_id,
      i.oracle_sid,
      i.edition,
      cf.cpu_sockets,
      cf.total_physical_cores,
      cf.core_factor,
      -- NUP minimum: 25 per EE processor licence, 10 per SE2 processor licence
      CASE
        WHEN i.edition ILIKE '%%Enterprise%%'
          THEN ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
        WHEN i.edition ILIKE '%%Standard Edition 2%%'
          THEN (LEAST(cf.cpu_sockets, 2) * 10)::NUMERIC
        WHEN i.edition ILIKE '%%Standard%%'
          THEN (cf.cpu_sockets * 10)::NUMERIC
        ELSE ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
      END                          AS nup_minimum_required,
      n.active_user_count,
      n.total_user_count,
      n.locked_user_count,
      n.snapshot_date              AS nup_snapshot_date,
      -- Actual users vs minimum required
      CASE
        WHEN n.active_user_count IS NULL THEN 'NO_DATA'
        WHEN n.active_user_count >= (
          CASE
            WHEN i.edition ILIKE '%%Enterprise%%'
              THEN ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
            WHEN i.edition ILIKE '%%Standard Edition 2%%'
              THEN (LEAST(cf.cpu_sockets, 2) * 10)::NUMERIC
            ELSE ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
          END
        ) THEN 'ACTUAL_EXCEEDS_MINIMUM'
        ELSE 'MINIMUM_APPLIES'
      END                          AS nup_basis,
      -- Effective NUP count to licence (greater of actual or minimum)
      GREATEST(
        COALESCE(n.active_user_count, 0)::NUMERIC,
        CASE
          WHEN i.edition ILIKE '%%Enterprise%%'
            THEN ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
          WHEN i.edition ILIKE '%%Standard Edition 2%%'
            THEN (LEAST(cf.cpu_sockets, 2) * 10)::NUMERIC
          ELSE ROUND(cf.total_physical_cores * cf.core_factor * 25, 0)
        END
      )                            AS effective_nup_to_licence
    FROM   %I.oracle_servers    s
    JOIN   %I.oracle_instances  i  ON i.server_id = s.server_id AND i.is_active
    JOIN   core_factor          cf ON cf.server_id = s.server_id
    LEFT   JOIN latest_nup      n  ON n.instance_id = i.instance_id
    WHERE  s.is_active = TRUE
    ORDER  BY s.hostname, i.oracle_sid
  $view$, p_schema,
  p_schema, p_schema, p_schema,
  p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- OCI LICENCE POSITION VIEW
  -- Shows OCI instances with their licensing model.
  -- BYOL = customer provides their own licences (counted in license_position).
  -- Licence-included = Oracle charges for the licence within OCI pricing.
  -- -------------------------------------------------------------------------
  EXECUTE format('DROP VIEW IF EXISTS %I.oci_licence_position CASCADE', p_schema);
  EXECUTE format($view$
    CREATE VIEW %I.oci_licence_position AS
    SELECT
      o.oci_id,
      o.oci_instance_id,
      o.display_name,
      o.region,
      o.availability_domain,
      o.compartment_name,
      o.shape,
      o.ocpu_count,
      o.memory_gb,
      o.image_os,
      o.lifecycle_state,
      o.oracle_db_edition,
      o.is_byol,
      o.private_ip,
      o.public_ip,
      o.last_seen,
      s.hostname,
      s.environment::TEXT,
      CASE
        WHEN o.is_byol THEN
          'BYOL — include in on-premises licence position calculations'
        ELSE
          'Licence-included — Oracle bills within OCI; no separate CSI required'
      END  AS licensing_note,
      CASE
        WHEN o.is_byol AND o.oracle_db_edition IS NOT NULL THEN
          ROUND(o.ocpu_count * 0.5, 2)
        ELSE NULL
      END  AS byol_processor_licences_required
    FROM   %I.oci_instances  o
    LEFT   JOIN %I.oracle_servers s ON s.server_id = o.server_id
    WHERE  o.lifecycle_state NOT IN ('TERMINATED', 'TERMINATING')
       OR  o.lifecycle_state IS NULL
    ORDER  BY o.region, o.display_name
  $view$, p_schema, p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- PDB MULTITENANT VIEW
  -- Shows CDBs with their PDB count and whether Multitenant is required.
  -- Oracle requires the Multitenant option when a CDB has more than 1 PDB
  -- (the CDB itself counts as 1; a second user PDB triggers the option).
  -- -------------------------------------------------------------------------
  EXECUTE format('DROP VIEW IF EXISTS %I.pdb_multitenant_position CASCADE', p_schema);
  EXECUTE format($view$
    CREATE VIEW %I.pdb_multitenant_position AS
    SELECT
      s.server_id,
      s.hostname,
      s.environment::TEXT,
      i.instance_id,
      i.oracle_sid,
      i.edition,
      i.db_version,
      COUNT(p.pdb_id)                                       AS total_pdb_count,
      COUNT(p.pdb_id) FILTER (WHERE NOT p.is_cdb_root)     AS user_pdb_count,
      BOOL_OR(p.requires_multitenant_licence)               AS multitenant_licence_required,
      STRING_AGG(p.pdb_name || ' (' || COALESCE(p.open_mode,'?') || ')',
                 ', ' ORDER BY p.pdb_name)                  AS pdb_list,
      CASE
        WHEN COUNT(p.pdb_id) FILTER (WHERE NOT p.is_cdb_root) > 1
          THEN 'MULTITENANT_LICENCE_REQUIRED'
        WHEN COUNT(p.pdb_id) FILTER (WHERE NOT p.is_cdb_root) = 1
          THEN 'SINGLE_PDB_FREE'
        WHEN COUNT(p.pdb_id) = 0
          THEN 'NON_CDB'
        ELSE 'REVIEW_REQUIRED'
      END                                                   AS multitenant_status
    FROM   %I.oracle_servers    s
    JOIN   %I.oracle_instances  i  ON i.server_id  = s.server_id AND i.is_active
    LEFT   JOIN %I.oracle_pdbs  p  ON p.instance_id = i.instance_id
    WHERE  s.is_active = TRUE
    GROUP  BY s.server_id, s.hostname, s.environment,
              i.instance_id, i.oracle_sid, i.edition, i.db_version
    ORDER  BY multitenant_licence_required DESC NULLS LAST,
              s.hostname, i.oracle_sid
  $view$, p_schema, p_schema, p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- UPSERT_ORACLE_EXTENDED_DISCOVERY
  -- Called after upsert_oracle_discovery to load RAC nodes, PDBs, and
  -- NUP user counts discovered in the extended playbook queries.
  -- -------------------------------------------------------------------------
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.upsert_oracle_extended_discovery(p_payload JSONB)
    RETURNS VOID LANGUAGE plpgsql AS $body$
    DECLARE
      v_server_id   INTEGER;
      v_instance_id INTEGER;
      v_inst        JSONB;
      v_node        JSONB;
      v_pdb         JSONB;
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
        FOR v_pdb IN SELECT * FROM jsonb_array_elements(COALESCE(v_inst->'pdbs', '[]'::jsonb))
        LOOP
          -- Count user PDBs to determine Multitenant licence requirement
          SELECT COUNT(*) INTO v_pdb_count
          FROM   %I.oracle_pdbs
          WHERE  instance_id = v_instance_id
            AND  NOT is_cdb_root
            AND  pdb_name <> (v_pdb->>'pdb_name');

          INSERT INTO %I.oracle_pdbs
            (instance_id, pdb_name, pdb_con_id, open_mode, restricted,
             is_cdb_root, requires_multitenant_licence,
             last_seen, discovery_run_id)
          VALUES (
            v_instance_id,
            v_pdb->>'pdb_name',
            (v_pdb->>'con_id')::INTEGER,
            v_pdb->>'open_mode',
            v_pdb->>'restricted',
            (COALESCE(v_pdb->>'con_id', '0') = '1')::BOOLEAN,
            -- Multitenant licence required when there will be > 1 user PDB
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

      END LOOP;
    END;
    $body$;
  $fn$,
  p_schema, p_schema, p_schema,
  p_schema, p_schema, p_schema,
  p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- UPSERT_JAVA_DISCOVERY
  -- Called by the Java discovery Ansible playbook.
  -- -------------------------------------------------------------------------
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.upsert_java_discovery(p_payload JSONB)
    RETURNS VOID LANGUAGE plpgsql AS $body$
    DECLARE
      v_server_id INTEGER;
      v_install   JSONB;
      v_licensed  BOOLEAN;
      v_metric    TEXT;
    BEGIN
      -- Ensure server record exists
      INSERT INTO %I.oracle_servers
        (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
         environment, total_ram_mb, last_seen, last_discovery_run)
      VALUES (
        p_payload->>'hostname', p_payload->>'fqdn',
        (p_payload->>'ip_address')::INET,
        p_payload->>'os_family', p_payload->>'os_distribution',
        p_payload->>'os_version',
        (COALESCE(p_payload->>'environment', 'unknown'))::environment_type,
        (p_payload->>'total_ram_mb')::INTEGER,
        NOW(), p_payload->>'run_id'
      )
      ON CONFLICT (hostname) DO UPDATE SET
        last_seen          = NOW(),
        last_discovery_run = EXCLUDED.last_discovery_run
      RETURNING server_id INTO v_server_id;

      FOR v_install IN SELECT * FROM jsonb_array_elements(p_payload->'java_installations')
      LOOP
        -- Classify licensing based on vendor and version
        SELECT requires_licence, licence_metric
        INTO   v_licensed, v_metric
        FROM   shared.java_license_editions
        WHERE  edition_name = v_install->>'java_edition'
        LIMIT  1;

        INSERT INTO %I.java_installations
          (server_id, java_home, java_vendor, java_version,
           java_major_version, java_edition, is_oracle_jdk,
           requires_licence, licence_metric,
           last_seen, discovery_run_id)
        VALUES (
          v_server_id,
          v_install->>'java_home',
          v_install->>'java_vendor',
          v_install->>'java_version',
          (v_install->>'java_major_version')::INTEGER,
          v_install->>'java_edition',
          (COALESCE(v_install->>'is_oracle_jdk', 'false'))::BOOLEAN,
          COALESCE(v_licensed, FALSE),
          v_metric,
          NOW(), p_payload->>'run_id'
        )
        ON CONFLICT (server_id, java_home) DO UPDATE SET
          java_vendor        = EXCLUDED.java_vendor,
          java_version       = EXCLUDED.java_version,
          java_major_version = EXCLUDED.java_major_version,
          java_edition       = EXCLUDED.java_edition,
          is_oracle_jdk      = EXCLUDED.is_oracle_jdk,
          requires_licence   = EXCLUDED.requires_licence,
          licence_metric     = EXCLUDED.licence_metric,
          last_seen          = NOW(),
          discovery_run_id   = EXCLUDED.discovery_run_id;
          -- Exemption fields are intentionally excluded: discovery never
          -- clears a manually-set exemption.
      END LOOP;
    END;
    $body$;
  $fn$,
  p_schema, p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- UPSERT_MYSQL_DISCOVERY
  -- Called by the MySQL discovery Ansible playbook.
  -- -------------------------------------------------------------------------
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.upsert_mysql_discovery(p_payload JSONB)
    RETURNS VOID LANGUAGE plpgsql AS $body$
    DECLARE
      v_server_id INTEGER;
      v_install   JSONB;
      v_licensed  BOOLEAN;
    BEGIN
      INSERT INTO %I.oracle_servers
        (hostname, fqdn, ip_address, os_family, os_distribution, os_version,
         environment, total_ram_mb, last_seen, last_discovery_run)
      VALUES (
        p_payload->>'hostname', p_payload->>'fqdn',
        (p_payload->>'ip_address')::INET,
        p_payload->>'os_family', p_payload->>'os_distribution',
        p_payload->>'os_version',
        (COALESCE(p_payload->>'environment', 'unknown'))::environment_type,
        (p_payload->>'total_ram_mb')::INTEGER,
        NOW(), p_payload->>'run_id'
      )
      ON CONFLICT (hostname) DO UPDATE SET
        last_seen          = NOW(),
        last_discovery_run = EXCLUDED.last_discovery_run
      RETURNING server_id INTO v_server_id;

      FOR v_install IN SELECT * FROM jsonb_array_elements(p_payload->'mysql_installations')
      LOOP
        SELECT requires_licence INTO v_licensed
        FROM   shared.mysql_license_editions
        WHERE  edition_name = v_install->>'mysql_edition'
        LIMIT  1;

        INSERT INTO %I.mysql_installations
          (server_id, mysql_version, mysql_edition, install_path,
           data_dir, port, is_enterprise, requires_licence,
           last_seen, discovery_run_id)
        VALUES (
          v_server_id,
          v_install->>'mysql_version',
          v_install->>'mysql_edition',
          v_install->>'install_path',
          v_install->>'data_dir',
          (v_install->>'port')::INTEGER,
          (COALESCE(v_install->>'is_enterprise', 'false'))::BOOLEAN,
          COALESCE(v_licensed, FALSE),
          NOW(), p_payload->>'run_id'
        )
        ON CONFLICT (server_id, COALESCE(install_path, 'unknown')) DO UPDATE SET
          mysql_version    = EXCLUDED.mysql_version,
          mysql_edition    = EXCLUDED.mysql_edition,
          data_dir         = EXCLUDED.data_dir,
          port             = EXCLUDED.port,
          is_enterprise    = EXCLUDED.is_enterprise,
          requires_licence = EXCLUDED.requires_licence,
          last_seen        = NOW(),
          discovery_run_id = EXCLUDED.discovery_run_id;
      END LOOP;
    END;
    $body$;
  $fn$,
  p_schema, p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- UPSERT_OCI_DISCOVERY
  -- Called by the OCI discovery Ansible playbook.
  -- -------------------------------------------------------------------------
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.upsert_oci_discovery(p_payload JSONB)
    RETURNS VOID LANGUAGE plpgsql AS $body$
    DECLARE
      v_instance JSONB;
      v_server_id INTEGER;
    BEGIN
      FOR v_instance IN SELECT * FROM jsonb_array_elements(p_payload->'instances')
      LOOP
        -- Try to match to a known server by private IP
        SELECT server_id INTO v_server_id
        FROM   %I.oracle_servers
        WHERE  ip_address = (v_instance->>'private_ip')::INET
        LIMIT  1;

        INSERT INTO %I.oci_instances
          (oci_instance_id, display_name, compartment_id, compartment_name,
           availability_domain, region, shape, ocpu_count, memory_gb,
           image_os, lifecycle_state, is_byol, oracle_db_edition,
           private_ip, public_ip, server_id,
           last_seen, discovery_run_id)
        VALUES (
          v_instance->>'id',
          v_instance->>'display_name',
          v_instance->>'compartment_id',
          v_instance->>'compartment_name',
          v_instance->>'availability_domain',
          v_instance->>'region',
          v_instance->>'shape',
          (v_instance->>'ocpu_count')::NUMERIC,
          (v_instance->>'memory_gb')::NUMERIC,
          v_instance->>'image_os',
          v_instance->>'lifecycle_state',
          (COALESCE(v_instance->>'is_byol', 'false'))::BOOLEAN,
          v_instance->>'oracle_db_edition',
          v_instance->>'private_ip',
          v_instance->>'public_ip',
          v_server_id,
          NOW(), p_payload->>'run_id'
        )
        ON CONFLICT (oci_instance_id) DO UPDATE SET
          display_name         = EXCLUDED.display_name,
          compartment_name     = EXCLUDED.compartment_name,
          lifecycle_state      = EXCLUDED.lifecycle_state,
          ocpu_count           = EXCLUDED.ocpu_count,
          memory_gb            = EXCLUDED.memory_gb,
          is_byol              = EXCLUDED.is_byol,
          oracle_db_edition    = EXCLUDED.oracle_db_edition,
          private_ip           = EXCLUDED.private_ip,
          public_ip            = EXCLUDED.public_ip,
          server_id            = COALESCE(EXCLUDED.server_id, %I.oci_instances.server_id),
          last_seen            = NOW(),
          discovery_run_id     = EXCLUDED.discovery_run_id;
      END LOOP;
    END;
    $body$;
  $fn$,
  p_schema, p_schema, p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- SE2 VIOLATIONS VIEW
  -- Flags servers/instances that violate Oracle SE2 licensing rules.
  EXECUTE format('DROP VIEW IF EXISTS %I.se2_violations CASCADE', p_schema);
  -- SE2 rules: max 2 CPU sockets per server; max 2 nodes in a RAC cluster.
  -- -------------------------------------------------------------------------
  EXECUTE format($view$
    CREATE VIEW %I.se2_violations AS
    WITH socket_check AS (
      SELECT
        s.server_id,
        s.hostname,
        i.instance_id,
        i.oracle_sid,
        i.edition,
        p.cpu_sockets,
        CASE WHEN p.cpu_sockets > 2 THEN TRUE ELSE FALSE END AS socket_violation
      FROM   %I.oracle_servers s
      JOIN   %I.oracle_instances i ON i.server_id = s.server_id AND i.is_active
      JOIN   LATERAL (
        SELECT cpu_sockets FROM %I.oracle_processors
        WHERE  server_id = s.server_id ORDER BY recorded_at DESC LIMIT 1
      ) p ON TRUE
      WHERE  s.is_active
        AND  (i.edition ILIKE '%%Standard Edition 2%%' OR i.edition = 'SE2')
    ),
    rac_check AS (
      SELECT
        i.instance_id,
        i.oracle_sid,
        COUNT(DISTINCT n.node_name) AS rac_node_count,
        CASE WHEN COUNT(DISTINCT n.node_name) > 2 THEN TRUE ELSE FALSE END AS rac_violation
      FROM   %I.oracle_instances i
      JOIN   %I.oracle_rac_nodes n ON n.instance_id = i.instance_id
      WHERE  i.is_active
        AND  (i.edition ILIKE '%%Standard Edition 2%%' OR i.edition = 'SE2')
      GROUP  BY i.instance_id, i.oracle_sid
    )
    SELECT
      sc.server_id,
      sc.hostname,
      sc.oracle_sid,
      sc.edition,
      sc.cpu_sockets,
      COALESCE(rc.rac_node_count, 1)              AS rac_node_count,
      sc.socket_violation,
      COALESCE(rc.rac_violation, FALSE)            AS rac_violation,
      CASE
        WHEN sc.socket_violation AND COALESCE(rc.rac_violation, FALSE)
          THEN 'SOCKET + RAC SIZE'
        WHEN sc.socket_violation
          THEN 'SOCKET LIMIT (' || sc.cpu_sockets || ' > 2)'
        WHEN COALESCE(rc.rac_violation, FALSE)
          THEN 'RAC SIZE (' || rc.rac_node_count || ' nodes > 2)'
        ELSE 'OK'
      END                                         AS violation_summary
    FROM   socket_check sc
    LEFT   JOIN rac_check rc ON rc.instance_id = sc.instance_id
    WHERE  sc.socket_violation OR COALESCE(rc.rac_violation, FALSE)
  $view$,
  p_schema, p_schema, p_schema, p_schema,
  p_schema, p_schema);

  -- -------------------------------------------------------------------------
  -- CPU VALIDATION REPORT VIEW
  -- Surfaces servers whose CPU model is not found in the Oracle Processor
  -- Core Factor Table (shared.core_factor_table).  An unrecognised model
  -- means the licence calculation may be using the wrong factor.
  EXECUTE format('DROP VIEW IF EXISTS %I.cpu_validation_report CASCADE', p_schema);
  -- -------------------------------------------------------------------------
  EXECUTE format($view$
    CREATE VIEW %I.cpu_validation_report AS
    SELECT
      s.server_id,
      s.hostname,
      s.environment::TEXT,
      p.cpu_model,
      p.cpu_sockets,
      p.cores_per_socket,
      p.cpu_sockets * p.cores_per_socket           AS total_physical_cores,
      shared.cpu_core_factor_lookup(p.cpu_model)   AS validated_factor,
      shared.cpu_core_factor_lookup(p.cpu_model) IS NULL AS factor_unknown,
      CASE
        WHEN shared.cpu_core_factor_lookup(p.cpu_model) IS NULL
          THEN 'UNRECOGNISED — verify at oracle.com/assets/processor-core-factor-table-070634.pdf'
        ELSE 'OK (factor = ' || shared.cpu_core_factor_lookup(p.cpu_model) || ')'
      END                                          AS validation_status,
      p.recorded_at                                AS last_processor_snapshot
    FROM   %I.oracle_servers s
    JOIN   LATERAL (
      SELECT cpu_model, cpu_sockets, cores_per_socket, recorded_at
      FROM   %I.oracle_processors
      WHERE  server_id = s.server_id
      ORDER  BY recorded_at DESC LIMIT 1
    ) p ON TRUE
    WHERE  s.is_active
    ORDER  BY factor_unknown DESC, s.hostname
  $view$,
  p_schema, p_schema, p_schema);

END;
$$;

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
      PERFORM sam_admin.install_changelog_objects(v_client.schema_name);
      PERFORM sam_admin.install_upsert_functions(v_client.schema_name);
      PERFORM sam_admin.install_extended_views(v_client.schema_name);
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

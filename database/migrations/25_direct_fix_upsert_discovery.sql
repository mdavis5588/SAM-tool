-- Migration 25: Directly patch upsert_oracle_discovery in every client schema
--              to set is_active = TRUE on ON CONFLICT.
--
-- Previous migrations (22/24) called install_upsert_functions, but that
-- meta-function itself was never updated in the live DB (the source file
-- 03_client_template_functions.sql was edited but never re-run against the DB).
-- This migration fixes it by:
--   1. Updating sam_admin.install_upsert_functions with the corrected body
--   2. Re-running it for every client schema so the per-schema functions are updated

-- Step 1: Update sam_admin.install_upsert_functions to embed is_active = TRUE
--         We do this by creating a targeted helper that just recreates
--         upsert_oracle_discovery for a given schema, then applying it.
CREATE OR REPLACE FUNCTION sam_admin._patch_upsert_discovery(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.upsert_oracle_discovery(p_payload JSONB)
    RETURNS VOID LANGUAGE plpgsql AS $body$
    DECLARE
      v_server_id  INTEGER;
      v_instance   JSONB;
    BEGIN
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
        last_discovery_run = EXCLUDED.last_discovery_run,
        is_active          = TRUE
      RETURNING server_id INTO v_server_id;

      INSERT INTO %I.oracle_processors
        (server_id, cpu_model, cpu_architecture, cpu_sockets, cores_per_socket,
         threads_per_core, virt_type, is_vmware, is_exadata, vcpu_count, discovery_run_id)
      VALUES (
        v_server_id,
        p_payload->>'cpu_model',
        p_payload->>'cpu_architecture',
        (p_payload->>'cpu_sockets')::INTEGER,
        (p_payload->>'cpu_cores_per_socket')::INTEGER,
        (p_payload->>'cpu_threads_per_core')::INTEGER,
        (COALESCE(p_payload->>'virt_type','unknown'))::virt_type,
        COALESCE((p_payload->>'is_vmware')::BOOLEAN, FALSE),
        COALESCE((p_payload->>'is_exadata')::BOOLEAN, FALSE),
        (p_payload->>'vcpu_count')::INTEGER,
        p_payload->>'run_id'
      );

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
          discovery_run_id = EXCLUDED.discovery_run_id,
          is_active        = TRUE;
      END LOOP;
    END;
    $body$;
  $fn$,
  p_schema,   -- 1: function schema
  p_schema,   -- 2: oracle_servers
  p_schema,   -- 3: oracle_processors
  p_schema,   -- 4: oracle_instances
  p_schema);  -- 5: (matches original 5-arg call)
END;
$$;

-- Step 2: Apply to all client schemas
DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin._patch_upsert_discovery(v_client.schema_name);
    RAISE NOTICE 'Patched upsert_oracle_discovery for %', v_client.schema_name;
  END LOOP;
END;
$$;

-- Step 3: Clean up helper (not needed after migration)
DROP FUNCTION IF EXISTS sam_admin._patch_upsert_discovery(TEXT);

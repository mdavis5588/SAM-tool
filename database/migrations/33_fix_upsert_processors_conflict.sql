-- Migration 33: Fix oracle_processors upsert — update existing row instead of
--              inserting a duplicate, so re-uploads refresh processor data.
--
-- oracle_processors has no UNIQUE constraint on server_id (it's a history table
-- by design).  The plain INSERT in previous versions of upsert_oracle_discovery
-- appended a new row every upload and never updated existing data, so cpu_model,
-- cpu_sockets, is_exadata etc. were blank after the first upload.
--
-- The fix: check whether a row for the server already exists and UPDATE it;
-- INSERT only when none exists yet.

CREATE OR REPLACE FUNCTION sam_admin._patch_upsert_processors(p_schema TEXT)
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

      -- Update existing processor row if present; insert only when absent.
      -- (oracle_processors has no UNIQUE constraint on server_id — it stores
      --  a history — so ON CONFLICT cannot be used here.)
      IF EXISTS (SELECT 1 FROM %I.oracle_processors WHERE server_id = v_server_id) THEN
        UPDATE %I.oracle_processors SET
          cpu_model        = p_payload->>'cpu_model',
          cpu_architecture = p_payload->>'cpu_architecture',
          cpu_sockets      = (p_payload->>'cpu_sockets')::INTEGER,
          cores_per_socket = (p_payload->>'cpu_cores_per_socket')::INTEGER,
          threads_per_core = (p_payload->>'cpu_threads_per_core')::INTEGER,
          virt_type        = (COALESCE(p_payload->>'virt_type','unknown'))::virt_type,
          is_vmware        = COALESCE((p_payload->>'is_vmware')::BOOLEAN, FALSE),
          is_exadata       = COALESCE((p_payload->>'is_exadata')::BOOLEAN, FALSE),
          vcpu_count       = (p_payload->>'vcpu_count')::INTEGER,
          discovery_run_id = p_payload->>'run_id',
          recorded_at      = NOW()
        WHERE server_id = v_server_id;
      ELSE
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
      END IF;

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
  p_schema,   -- 3: oracle_processors (EXISTS check)
  p_schema,   -- 4: oracle_processors (UPDATE)
  p_schema,   -- 5: oracle_processors (INSERT)
  p_schema,   -- 6: oracle_instances
  p_schema);  -- 7: (matches 7-arg format call)
END;
$$;

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin._patch_upsert_processors(v_client.schema_name);
    RAISE NOTICE 'Patched upsert_oracle_discovery for %', v_client.schema_name;
  END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS sam_admin._patch_upsert_processors(TEXT);

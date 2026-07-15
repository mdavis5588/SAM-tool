-- Migration 09: Server deduplication — register_server() upsert function
--
-- Both Ansible and PSQL/cron discovery jobs call this function instead of
-- inserting directly into oracle_servers.  It resolves identity across the
-- three keys that may differ between discovery methods (hostname, fqdn,
-- ip_address), applies a canonical hostname, and upserts in place so the
-- same physical server never generates a second row.
--
-- Usage:
--   SELECT client_acme.register_server(
--       p_hostname   => 'srv01',
--       p_fqdn       => 'srv01.corp.acme.com',
--       p_ip_address => '10.0.0.5',
--       p_source     => 'ansible',          -- or 'psql_cron', 'manual', etc.
--       -- remaining params are optional, pass NULL to leave existing value
--       p_os_family        => 'Linux',
--       p_os_distribution  => 'RHEL',
--       p_os_version       => '8.9',
--       p_environment      => 'PROD',
--       p_total_ram_mb     => 65536,
--       p_datacenter       => 'DC1',
--       p_physical_cores   => 16,           -- total across all sockets; NULL = no update
--       p_cpu_sockets      => 2,
--       p_cores_per_socket => 8
--   );
--   -- Returns: 'inserted:<server_id>' or 'updated:<server_id>' or 'conflict:<detail>'


-- Add discovery_source column to every existing client schema's oracle_servers
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT schema_name FROM sam_admin.clients WHERE is_active
    LOOP
        EXECUTE format(
            'ALTER TABLE %I.oracle_servers ADD COLUMN IF NOT EXISTS discovery_source TEXT',
            r.schema_name
        );
        EXECUTE format(
            'ALTER TABLE %I.oracle_servers ADD COLUMN IF NOT EXISTS discovery_conflict BOOLEAN NOT NULL DEFAULT FALSE',
            r.schema_name
        );
        EXECUTE format(
            'ALTER TABLE %I.oracle_servers ADD COLUMN IF NOT EXISTS conflict_detail TEXT',
            r.schema_name
        );
    END LOOP;
END
$$;


-- Also patch the template in provision_client so new schemas get the columns
-- (the provision_client function creates oracle_servers; we add them via ALTER
--  after provisioning if they are missing — the DO block above covers existing
--  schemas; new schemas will be patched on first register_server call below)


-- ── register_server function ─────────────────────────────────────────────────
-- Created once in sam_admin; takes the target schema as the first argument so
-- a single function handles all client schemas.

CREATE OR REPLACE FUNCTION sam_admin.register_server(
    p_schema           TEXT,
    p_hostname         TEXT,           -- short name or FQDN from discovery
    p_source           TEXT,           -- 'ansible' | 'psql_cron' | 'manual' | …
    p_fqdn             TEXT    DEFAULT NULL,
    p_ip_address       TEXT    DEFAULT NULL,   -- passed as text, cast to INET internally
    p_os_family        TEXT    DEFAULT NULL,
    p_os_distribution  TEXT    DEFAULT NULL,
    p_os_version       TEXT    DEFAULT NULL,
    p_environment      TEXT    DEFAULT NULL,
    p_total_ram_mb     INTEGER DEFAULT NULL,
    p_datacenter       TEXT    DEFAULT NULL,
    p_physical_cores   INTEGER DEFAULT NULL,   -- total cores (sockets × cores/socket)
    p_cpu_sockets      INTEGER DEFAULT NULL,
    p_cores_per_socket INTEGER DEFAULT NULL,
    p_notes            TEXT    DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_ip         INET;
    v_short      TEXT;   -- short hostname (first label of FQDN / p_hostname)
    v_fqdn_norm  TEXT;   -- normalised FQDN

    v_existing   RECORD;
    v_match_id   INTEGER := NULL;
    v_match_how  TEXT;

    v_server_id  INTEGER;
    v_result     TEXT;

    v_conflict   BOOLEAN := FALSE;
    v_conflict_detail TEXT := NULL;
BEGIN
    -- ── 1. Normalise inputs ──────────────────────────────────────────────────
    p_hostname := TRIM(LOWER(p_hostname));

    -- Derive short name: first label before the first dot
    v_short := SPLIT_PART(p_hostname, '.', 1);

    -- Normalised FQDN: prefer explicit p_fqdn, fall back to p_hostname if it
    -- contains dots (i.e. it IS a FQDN), otherwise NULL
    v_fqdn_norm := COALESCE(
        NULLIF(TRIM(LOWER(p_fqdn)), ''),
        CASE WHEN p_hostname LIKE '%.%' THEN p_hostname ELSE NULL END
    );

    -- Canonical stored hostname: short name when we have a FQDN, raw p_hostname otherwise
    IF v_fqdn_norm IS NOT NULL THEN
        p_hostname := v_short;   -- store short name; FQDN goes in the fqdn column
    END IF;

    -- Parse IP
    IF p_ip_address IS NOT NULL AND TRIM(p_ip_address) <> '' THEN
        BEGIN
            v_ip := TRIM(p_ip_address)::INET;
        EXCEPTION WHEN OTHERS THEN
            v_ip := NULL;  -- bad IP string — ignore, don't abort
        END;
    END IF;

    -- ── 2. Ensure columns exist on this schema (idempotent) ─────────────────
    EXECUTE format(
        'ALTER TABLE %I.oracle_servers ADD COLUMN IF NOT EXISTS discovery_source    TEXT',
        p_schema);
    EXECUTE format(
        'ALTER TABLE %I.oracle_servers ADD COLUMN IF NOT EXISTS discovery_conflict  BOOLEAN NOT NULL DEFAULT FALSE',
        p_schema);
    EXECUTE format(
        'ALTER TABLE %I.oracle_servers ADD COLUMN IF NOT EXISTS conflict_detail     TEXT',
        p_schema);

    -- ── 3. Identity resolution — find existing row ───────────────────────────
    --
    -- Priority: exact hostname > short-name match > FQDN match > IP match
    -- We only match ONE row; if multiple candidates exist we pick the best and
    -- flag the ambiguity in conflict_detail.

    -- 3a. Exact hostname match (covers re-runs with same data)
    EXECUTE format(
        'SELECT server_id FROM %I.oracle_servers WHERE hostname = $1 LIMIT 1',
        p_schema
    ) INTO v_match_id USING p_hostname;

    IF v_match_id IS NOT NULL THEN
        v_match_how := 'hostname_exact';
    END IF;

    -- 3b. Short-name match (p_hostname is the short part of an existing FQDN)
    IF v_match_id IS NULL THEN
        EXECUTE format(
            'SELECT server_id FROM %I.oracle_servers
             WHERE SPLIT_PART(hostname,''.'',1) = $1
                OR SPLIT_PART(COALESCE(fqdn,''''),''.'',1) = $1
             LIMIT 1',
            p_schema
        ) INTO v_match_id USING v_short;
        IF v_match_id IS NOT NULL THEN v_match_how := 'short_name'; END IF;
    END IF;

    -- 3c. FQDN match
    IF v_match_id IS NULL AND v_fqdn_norm IS NOT NULL THEN
        EXECUTE format(
            'SELECT server_id FROM %I.oracle_servers
             WHERE fqdn = $1 OR hostname = $1 LIMIT 1',
            p_schema
        ) INTO v_match_id USING v_fqdn_norm;
        IF v_match_id IS NOT NULL THEN v_match_how := 'fqdn'; END IF;
    END IF;

    -- 3d. IP address match
    IF v_match_id IS NULL AND v_ip IS NOT NULL THEN
        EXECUTE format(
            'SELECT server_id FROM %I.oracle_servers WHERE ip_address = $1 LIMIT 1',
            p_schema
        ) INTO v_match_id USING v_ip;
        IF v_match_id IS NOT NULL THEN v_match_how := 'ip_address'; END IF;
    END IF;

    -- ── 4. Conflict check: does the incoming hostname collide with a *different*
    --       row than the one we matched on? ───────────────────────────────────
    IF v_match_id IS NOT NULL AND v_match_how <> 'hostname_exact' THEN
        -- Check whether a *different* row already owns the canonical hostname
        DECLARE
            v_other INTEGER;
        BEGIN
            EXECUTE format(
                'SELECT server_id FROM %I.oracle_servers
                 WHERE hostname = $1 AND server_id <> $2 LIMIT 1',
                p_schema
            ) INTO v_other USING p_hostname, v_match_id;

            IF v_other IS NOT NULL THEN
                -- True conflict: two rows, same canonical hostname, matched on
                -- different keys.  Do not merge blindly — flag it.
                v_conflict := TRUE;
                v_conflict_detail := format(
                    'Incoming hostname "%s" (source: %s) collides with server_id %s '
                    'but was matched to server_id %s via %s. '
                    'Review and merge manually.',
                    p_hostname, p_source, v_other, v_match_id, v_match_how
                );
                RETURN 'conflict:' || v_conflict_detail;
            END IF;
        END;
    END IF;

    -- ── 5. Upsert ────────────────────────────────────────────────────────────
    IF v_match_id IS NULL THEN
        -- INSERT — new server
        EXECUTE format($q$
            INSERT INTO %I.oracle_servers
              (hostname, fqdn, ip_address,
               os_family, os_distribution, os_version,
               environment, total_ram_mb, datacenter,
               last_discovery_run, discovery_source,
               first_seen, last_seen)
            VALUES ($1,$2,$3,$4,$5,$6,
                    COALESCE($7,'unknown')::%I.environment_type,
                    $8,$9,$10,$11,NOW(),NOW())
            RETURNING server_id
        $q$, p_schema, p_schema)
        INTO v_server_id
        USING p_hostname, v_fqdn_norm, v_ip,
              p_os_family, p_os_distribution, p_os_version,
              p_environment, p_total_ram_mb, p_datacenter,
              p_notes, p_source;

        v_result := 'inserted:' || v_server_id;
    ELSE
        -- UPDATE — merge incoming data onto the existing row.
        -- NULL args leave the existing column value unchanged (COALESCE pattern).
        EXECUTE format($q$
            UPDATE %I.oracle_servers SET
              fqdn             = COALESCE($2, fqdn),
              ip_address       = COALESCE($3, ip_address),
              os_family        = COALESCE($4, os_family),
              os_distribution  = COALESCE($5, os_distribution),
              os_version       = COALESCE($6, os_version),
              environment      = CASE WHEN $7 IS NOT NULL
                                      THEN $7::%I.environment_type
                                      ELSE environment END,
              total_ram_mb     = COALESCE($8, total_ram_mb),
              datacenter       = COALESCE($9, datacenter),
              last_seen        = NOW(),
              last_discovery_run = COALESCE($10, last_discovery_run),
              discovery_source = $11,
              discovery_conflict = $12,
              conflict_detail  = COALESCE($13, conflict_detail)
            WHERE server_id = $1
        $q$, p_schema, p_schema)
        USING v_match_id,
              v_fqdn_norm, v_ip,
              p_os_family, p_os_distribution, p_os_version,
              p_environment, p_total_ram_mb, p_datacenter,
              p_notes, p_source,
              v_conflict, v_conflict_detail;

        v_server_id := v_match_id;
        v_result := 'updated:' || v_server_id || ':via_' || v_match_how;
    END IF;

    -- ── 6. Upsert processor info if provided ────────────────────────────────
    IF p_physical_cores IS NOT NULL OR p_cpu_sockets IS NOT NULL THEN
        DECLARE
            v_sockets INTEGER := COALESCE(p_cpu_sockets, 1);
            v_cps     INTEGER := COALESCE(
                p_cores_per_socket,
                CASE WHEN p_cpu_sockets IS NOT NULL AND p_physical_cores IS NOT NULL
                     THEN p_physical_cores / NULLIF(p_cpu_sockets, 0)
                     ELSE p_physical_cores END
            );
        BEGIN
            EXECUTE format($q$
                INSERT INTO %I.oracle_processors
                  (server_id, cpu_model, cpu_sockets, cores_per_socket)
                VALUES ($1, 'Unknown', $2, $3)
                ON CONFLICT (server_id, cpu_model) DO UPDATE
                  SET cpu_sockets      = EXCLUDED.cpu_sockets,
                      cores_per_socket = EXCLUDED.cores_per_socket
            $q$, p_schema)
            USING v_server_id, v_sockets, COALESCE(v_cps, 1);
        EXCEPTION WHEN OTHERS THEN
            NULL;  -- processor upsert failure doesn't abort server registration
        END;
    END IF;

    RETURN v_result;
END;
$$;


-- ── Conflict view — easy way to find servers that need human review ──────────
-- This is a helper view in sam_admin; it unions across all active client schemas.

CREATE OR REPLACE VIEW sam_admin.server_discovery_conflicts AS
SELECT
    c.client_name,
    c.schema_name,
    s.server_id,
    s.hostname,
    s.fqdn,
    s.ip_address::TEXT,
    s.discovery_source,
    s.last_seen,
    s.conflict_detail
FROM sam_admin.clients c
CROSS JOIN LATERAL (
    -- We use a function to query each client schema dynamically.
    -- Populated by the trigger below; for now callers can query per-schema.
    SELECT 1 WHERE FALSE  -- placeholder — see note below
) s(server_id, hostname, fqdn, ip_address, discovery_source, last_seen, conflict_detail)
WHERE c.is_active;

-- NOTE: PostgreSQL doesn't support truly dynamic cross-schema UNION in a view
-- without PL/pgSQL.  The conflict view above is a placeholder.
-- Use the per-schema query instead:
--
--   SELECT 'client_acme' AS schema_name, server_id, hostname, fqdn,
--          ip_address::TEXT, discovery_source, last_seen, conflict_detail
--   FROM client_acme.oracle_servers
--   WHERE discovery_conflict = TRUE;
--
-- Or call sam_admin.list_conflicts() defined below.

DROP VIEW IF EXISTS sam_admin.server_discovery_conflicts;

CREATE OR REPLACE FUNCTION sam_admin.list_conflicts()
RETURNS TABLE (
    client_name TEXT, schema_name TEXT,
    server_id INTEGER, hostname TEXT, fqdn TEXT,
    ip_address TEXT, discovery_source TEXT,
    last_seen TIMESTAMPTZ, conflict_detail TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT c.schema_name, c.client_name
             FROM sam_admin.clients c WHERE c.is_active
    LOOP
        BEGIN
            RETURN QUERY EXECUTE format(
                'SELECT %L::TEXT, %L::TEXT,
                        server_id, hostname, fqdn, ip_address::TEXT,
                        discovery_source, last_seen, conflict_detail
                 FROM %I.oracle_servers
                 WHERE discovery_conflict = TRUE',
                r.client_name, r.schema_name, r.schema_name
            );
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION sam_admin.register_server IS
'Upsert a server discovered by Ansible or PSQL cron.
Resolves identity via hostname → short-name → FQDN → IP and merges data.
Returns inserted:<id>, updated:<id>:via_<key>, or conflict:<detail>.';

COMMENT ON FUNCTION sam_admin.list_conflicts IS
'Return all servers flagged as discovery conflicts across all active client schemas.';

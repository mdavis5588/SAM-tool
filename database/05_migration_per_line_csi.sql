-- =============================================================================
-- Migration: per-line CSI assignment and oracle option licence lines
--
-- Run against your oracle_sam database AFTER the updated SQL scripts:
--   psql oracle_sam -f database/05_migration_per_line_csi.sql
--
-- Safe to re-run (all changes are IF NOT EXISTS / DO NOTHING).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Add shared.oracle_licensed_options (idempotent — in 02_shared_schema.sql
--    for new installs; needed here for existing databases)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shared.oracle_licensed_options (
  option_id       SERIAL PRIMARY KEY,
  option_name     TEXT NOT NULL UNIQUE,
  display_name    TEXT NOT NULL,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  notes           TEXT
);

INSERT INTO shared.oracle_licensed_options (option_name, display_name, notes) VALUES
  ('Partitioning',              'Oracle Partitioning',              'Separate EE option licence required'),
  ('Advanced Security',         'Oracle Advanced Security',         'TDE and network encryption'),
  ('Advanced Compression',      'Oracle Advanced Compression',      NULL),
  ('Diagnostics Pack',          'Oracle Diagnostics Pack',          'Includes AWR, ADDM, ASH'),
  ('Tuning Pack',               'Oracle Tuning Pack',               'Requires Diagnostics Pack'),
  ('Database Vault',            'Oracle Database Vault',            NULL),
  ('Label Security',            'Oracle Label Security',            NULL),
  ('Real Application Clusters', 'Oracle Real Application Clusters', 'Per-node licence required'),
  ('Active Data Guard',         'Oracle Active Data Guard',         'Standby read-only access'),
  ('Multitenant',               'Oracle Multitenant',               'Required when >1 PDB per CDB'),
  ('Database In-Memory',        'Oracle Database In-Memory',        NULL),
  ('Spatial and Graph',         'Oracle Spatial and Graph',         NULL),
  ('OLAP',                      'Oracle OLAP',                      NULL),
  ('Data Mining',               'Oracle Data Mining',               'In-database machine learning (OAA)')
ON CONFLICT (option_name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Add product_detail column to every client's server_csi_map
--    and replace the old unique constraint with an expression-based index
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_schema TEXT;
BEGIN
  FOR v_schema IN
    SELECT schema_name FROM sam_admin.clients WHERE is_active
  LOOP

    -- Add product_detail column if not present
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE  table_schema = v_schema
        AND  table_name   = 'server_csi_map'
        AND  column_name  = 'product_detail'
    ) THEN
      EXECUTE format(
        'ALTER TABLE %I.server_csi_map ADD COLUMN product_detail TEXT',
        v_schema
      );
      RAISE NOTICE 'Added product_detail column to %.server_csi_map', v_schema;
    END IF;

    -- Drop old unique constraint if it still exists
    IF EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE  conrelid = (v_schema || '.server_csi_map')::regclass
        AND  contype  = 'u'
        AND  conname  LIKE '%server_id%csi_id%'
    ) THEN
      EXECUTE format(
        'ALTER TABLE %I.server_csi_map DROP CONSTRAINT IF EXISTS server_csi_map_server_id_csi_id_line_id_product_family_key',
        v_schema
      );
      RAISE NOTICE 'Dropped old unique constraint from %.server_csi_map', v_schema;
    END IF;

    -- Create new expression-based unique index
    EXECUTE format(
      $idx$
        CREATE UNIQUE INDEX IF NOT EXISTS uix_%s_server_csi_line
          ON %I.server_csi_map (server_id, csi_id, product_family, COALESCE(product_detail, ''))
      $idx$,
      v_schema, v_schema
    );
    RAISE NOTICE 'Created unique index on %.server_csi_map', v_schema;

    -- Refresh the license_position view to include option lines
    PERFORM sam_admin.install_license_position_view(v_schema);
    RAISE NOTICE 'Refreshed license_position view for schema %', v_schema;

  END LOOP;
END $$;

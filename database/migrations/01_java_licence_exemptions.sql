-- =============================================================================
-- Migration 01: Java licence exemption columns
-- Adds licence_exempt, exempt_reason, exempt_notes, exempt_set_by, exempt_set_at
-- to java_installations in every active client schema.
--
-- Run this once against an existing database after upgrading the code:
--   psql oracle_sam -f database/migrations/01_java_licence_exemptions.sql
--
-- Safe to re-run — all statements use IF NOT EXISTS / IF EXISTS guards.
-- =============================================================================

DO $$
DECLARE
  v_schema TEXT;
BEGIN
  FOR v_schema IN
    SELECT schema_name FROM sam_admin.clients WHERE is_active
  LOOP
    RAISE NOTICE 'Migrating schema: %', v_schema;

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
    $ddl$, v_schema);

    -- Rebuild the java_licence_position view with the new columns
    PERFORM sam_admin.install_extended_views(v_schema);

    RAISE NOTICE '  ✓ %', v_schema;
  END LOOP;
END;
$$;

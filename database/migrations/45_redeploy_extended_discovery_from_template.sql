-- Migration 45: Redeploy upsert_oracle_extended_discovery from the canonical template.
--
-- Fixes "cannot extract elements from a scalar" raised by that function when
-- Oracle's JSON_ARRAYAGG emits a JSON null literal for nup_sample_users (and
-- likewise for rac_nodes, pdbs and feature_usage). COALESCE only replaces SQL
-- NULL, not a JSON null, so jsonb_array_elements_text was handed a scalar. The
-- guard is COALESCE(NULLIF(<value>, 'null'::jsonb), '[]'::jsonb).
--
-- 03_client_template_functions.sql already carries that guard, so this migration
-- simply reinstalls from it rather than restating the function body.
--
-- History, to explain why a fifth attempt exists:
--   42, 43  Did not take effect. Nested dollar-quoting inside format() meant the
--           live function was never replaced.
--   44      Does replace the live function, but from a body predating the
--           is_cdb_root and requires_multitenant_licence columns. The multitenant
--           view in 03_client_template_functions.sql reads both, so applying 44
--           leaves them unpopulated and silently breaks multitenant reporting.
--           Do not apply 44. This migration supersedes it.
--
-- Prerequisite: run database/03_client_template_functions.sql first, so the
-- sam_admin.install_* functions themselves are current.

DO $MIGR45$
DECLARE
  v_schema TEXT;
  v_count  INTEGER := 0;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'sam_admin'
      AND  p.proname = 'install_extended_views'
  ) THEN
    RAISE EXCEPTION
      'sam_admin.install_extended_views is missing. Run database/03_client_template_functions.sql first.';
  END IF;

  -- The installer is what carries the fix, so reinstalling from a stale copy
  -- would report success and change nothing. Refuse instead of doing that.
  IF NOT EXISTS (
    SELECT 1
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'sam_admin'
      AND  p.proname = 'install_extended_views'
      AND  p.prosrc LIKE '%NULLIF(v_inst->''nup_sample_users''%'
  ) THEN
    RAISE EXCEPTION
      'sam_admin.install_extended_views predates the nup_sample_users fix. '
      'Run database/03_client_template_functions.sql first, then this migration.';
  END IF;

  -- Every client, not just is_active, so a paused client is not left broken.
  FOR v_schema IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_extended_views(v_schema);
    v_count := v_count + 1;
    RAISE NOTICE 'Redeployed extended discovery for schema: %', v_schema;
  END LOOP;

  RAISE NOTICE 'Migration 45 complete: % schema(s) updated.', v_count;
END
$MIGR45$;

-- Verification: has_guard must be true for every schema.
SELECT n.nspname                                                    AS schema,
       p.prosrc LIKE '%NULLIF(v_inst->''nup_sample_users''%'         AS has_guard,
       p.prosrc LIKE '%requires_multitenant_licence%'                AS has_multitenant_cols
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  p.proname = 'upsert_oracle_extended_discovery'
ORDER  BY n.nspname;

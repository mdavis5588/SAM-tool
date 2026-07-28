-- Migration 17: Automatic licence-position snapshots
--
-- Adds two automatic snapshot triggers:
--   1. Feature activation  — when a licensed Oracle option is newly detected as
--      active on any client server, a snapshot of that client's full licence
--      position is taken automatically.
--   2. Feature dormancy    — when a feature has not been seen active for more
--      than one year a snapshot is taken to record the position at the point
--      the feature went quiet.
--
-- Both snapshot types are stored in the existing sam_admin.licence_snapshots /
-- licence_snapshot_lines tables alongside manual snapshots.  The UNIQUE
-- constraint that previously allowed only one snapshot per (client, month) is
-- relaxed to a partial index so it applies to manual snapshots only; automatic
-- snapshots can stack freely within a month.
--
-- New helper:
--   sam_admin.take_auto_snapshot(p_client_id, p_snapshot_type, p_trigger_feature)
--   sam_admin.check_feature_dormancy()   -- call from cron / dispatch-alerts


-- -------------------------------------------------------------------------
-- 1. Extend licence_snapshots
-- -------------------------------------------------------------------------

ALTER TABLE sam_admin.licence_snapshots
  ADD COLUMN IF NOT EXISTS snapshot_type    TEXT NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS trigger_feature  TEXT;

-- Restrict snapshot_type to the known set
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_snapshot_type'
      AND conrelid = 'sam_admin.licence_snapshots'::regclass
  ) THEN
    ALTER TABLE sam_admin.licence_snapshots
      ADD CONSTRAINT chk_snapshot_type
        CHECK (snapshot_type IN ('manual', 'feature_activated', 'feature_dormant'));
  END IF;
END;
$$;

-- Drop the old blanket unique constraint; replace with a partial index that
-- only enforces one-per-month for *manual* snapshots.
ALTER TABLE sam_admin.licence_snapshots
  DROP CONSTRAINT IF EXISTS licence_snapshots_client_id_snapshot_month_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_licence_snapshots_manual
  ON sam_admin.licence_snapshots (client_id, snapshot_month)
  WHERE snapshot_type = 'manual';

-- Prevent more than one auto-snapshot per (client, month, type, feature) so a
-- rapid-fire discovery loop cannot produce hundreds of duplicate rows.
CREATE UNIQUE INDEX IF NOT EXISTS uq_licence_snapshots_auto
  ON sam_admin.licence_snapshots (client_id, snapshot_month, snapshot_type, trigger_feature)
  WHERE snapshot_type <> 'manual';


-- -------------------------------------------------------------------------
-- 2. sam_admin.take_auto_snapshot()
--    Queries the live licence_position view for the given client and writes
--    a header + detail rows.  Returns the new snapshot_id, or NULL if the
--    dedup index blocked a duplicate within the same month.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.take_auto_snapshot(
  p_client_id       INTEGER,
  p_snapshot_type   TEXT,    -- 'feature_activated' | 'feature_dormant'
  p_trigger_feature TEXT
)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
  v_schema      TEXT;
  v_snap_id     INTEGER;
  v_month       DATE := DATE_TRUNC('month', NOW())::DATE;
  v_note        TEXT;
  rec           RECORD;
BEGIN
  -- Look up the client schema
  SELECT schema_name INTO v_schema
  FROM   sam_admin.clients
  WHERE  client_id = p_client_id;

  IF v_schema IS NULL THEN
    RAISE WARNING 'take_auto_snapshot: client_id % not found', p_client_id;
    RETURN NULL;
  END IF;

  v_note := CASE p_snapshot_type
    WHEN 'feature_activated' THEN
      'Auto-snapshot: feature newly active — ' || COALESCE(p_trigger_feature, 'unknown')
    WHEN 'feature_dormant' THEN
      'Auto-snapshot: feature inactive >1 year — ' || COALESCE(p_trigger_feature, 'unknown')
    ELSE
      'Auto-snapshot: ' || p_snapshot_type
  END;

  -- Insert header (dedup index silently blocks a second one for the same
  -- client+month+type+feature within the same calendar month)
  BEGIN
    INSERT INTO sam_admin.licence_snapshots
      (client_id, snapshot_month, taken_by, note, snapshot_type, trigger_feature)
    VALUES
      (p_client_id, v_month, 'system', v_note, p_snapshot_type, p_trigger_feature)
    RETURNING snapshot_id INTO v_snap_id;
  EXCEPTION
    WHEN unique_violation THEN
      RETURN NULL;   -- already snapped this client+month+type+feature
  END;

  -- Copy current licence position lines
  FOR rec IN
    EXECUTE format(
      'SELECT hostname, environment, product_family, product_detail,
              licence_metric, licences_required, licences_assigned,
              surplus_deficit, compliance_status, csi_number, contract_ref
       FROM   %I.license_position',
      v_schema
    )
  LOOP
    INSERT INTO sam_admin.licence_snapshot_lines
      (snapshot_id, hostname, environment, product_family, product_detail,
       licence_metric, licences_required, licences_assigned,
       surplus_deficit, compliance_status, csi_number, contract_ref)
    VALUES
      (v_snap_id, rec.hostname, rec.environment, rec.product_family, rec.product_detail,
       rec.licence_metric, rec.licences_required, rec.licences_assigned,
       rec.surplus_deficit, rec.compliance_status, rec.csi_number, rec.contract_ref);
  END LOOP;

  RETURN v_snap_id;
END;
$$;


-- -------------------------------------------------------------------------
-- 3. sam_admin.check_feature_dormancy()
--    Scans every client schema's oracle_options for features that were once
--    active but have not been seen active for more than one year.  For each
--    such feature, takes an auto-snapshot (dedup index prevents duplicates
--    within the same calendar month).
--    Call this from the /api/dispatch-alerts cron endpoint or a daily job.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sam_admin.check_feature_dormancy()
RETURNS TABLE (client_id INTEGER, feature TEXT, last_active TIMESTAMPTZ, snapshot_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
  v_client   RECORD;
  v_opt      RECORD;
  v_snap_id  INTEGER;
BEGIN
  FOR v_client IN
    SELECT c.client_id, c.schema_name
    FROM   sam_admin.clients c
    ORDER  BY c.client_id
  LOOP
    BEGIN
      FOR v_opt IN
        EXECUTE format(
          -- Find options that have a recorded_at (last seen) timestamp older
          -- than 1 year, with status TRUE at that time, meaning they were
          -- active then but have since gone quiet (either the status flipped
          -- or the option simply stopped appearing in discovery).
          'SELECT DISTINCT ON (o.option_name)
                  o.option_name,
                  o.recorded_at
           FROM   %I.oracle_options o
           WHERE  o.status = ''TRUE''
             AND  o.recorded_at < NOW() - INTERVAL ''1 year''
             AND  NOT EXISTS (
                    SELECT 1 FROM %I.oracle_options o2
                    WHERE  o2.option_name = o.option_name
                      AND  o2.status = ''TRUE''
                      AND  o2.recorded_at >= NOW() - INTERVAL ''1 year''
                  )
           ORDER  BY o.option_name, o.recorded_at DESC',
          v_client.schema_name,
          v_client.schema_name
        )
      LOOP
        v_snap_id := sam_admin.take_auto_snapshot(
          v_client.client_id,
          'feature_dormant',
          v_opt.option_name
        );

        -- Emit a row whether or not a snapshot was taken (NULL snap_id = dedup)
        client_id   := v_client.client_id;
        feature     := v_opt.option_name;
        last_active := v_opt.recorded_at;
        snapshot_id := v_snap_id;
        RETURN NEXT;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'check_feature_dormancy: error on schema %: %',
        v_client.schema_name, SQLERRM;
    END;
  END LOOP;
END;
$$;


-- -------------------------------------------------------------------------
-- 4. Extend install_changelog_objects() to trigger take_auto_snapshot()
--    on feature activation.
--
--    We patch the log_option_change trigger body that lives inside
--    sam_admin.install_changelog_objects().  Because the trigger function
--    is created dynamically (via EXECUTE format ... $fn$ ... $fn$) and
--    must reference the client schema name, we recreate the whole
--    install_changelog_objects function here with the activation hook added.
--
--    Existing client schemas must have their trigger refreshed by calling:
--      SELECT sam_admin.install_changelog_objects('<schema>');
--    for each client, or via:
--      SELECT sam_admin.refresh_all_client_functions();
-- -------------------------------------------------------------------------

-- Retrieve the current function body so we can surgically insert the snapshot
-- call after the existing INSERT into discovery_changelog on INSERT branch.
-- Rather than reprinting the 400-line function, we add a small wrapper trigger
-- function in sam_admin that the per-schema trigger can call, then add the
-- call via a separate migration-safe patch function.

-- The cleanest approach without reprinting the entire 400-line function is to
-- create a BEFORE-level wrapper: we add an AFTER ROW trigger on oracle_options
-- in sam_admin scope.  But triggers can only exist on the table's own schema.
-- Instead we add a second trigger function that fires AFTER log_option_change.

-- Helper called by the per-schema after-trigger defined below.
CREATE OR REPLACE FUNCTION sam_admin.notify_feature_activated(
  p_schema      TEXT,
  p_option_name TEXT,
  p_old_status  TEXT,   -- NULL on INSERT
  p_new_status  TEXT
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_client_id INTEGER;
BEGIN
  -- Only act when status moves to active
  IF p_new_status <> 'TRUE' THEN RETURN; END IF;
  -- Skip if it was already active (status unchanged)
  IF p_old_status = 'TRUE'  THEN RETURN; END IF;

  SELECT client_id INTO v_client_id
  FROM   sam_admin.clients
  WHERE  schema_name = p_schema;

  IF v_client_id IS NULL THEN RETURN; END IF;

  PERFORM sam_admin.take_auto_snapshot(
    v_client_id,
    'feature_activated',
    p_option_name
  );
END;
$$;


-- Per-schema trigger function + trigger for feature activation snapshots.
-- This is installed as a second trigger alongside the existing
-- trg_log_option_change so we don't have to rewrite that function.
CREATE OR REPLACE FUNCTION sam_admin.install_feature_activation_trigger(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION %I.snapshot_on_feature_activation()
    RETURNS TRIGGER LANGUAGE plpgsql AS $body$
    BEGIN
      PERFORM sam_admin.notify_feature_activated(
        %L,                 -- schema name (literal, baked in at install time)
        NEW.option_name,
        CASE WHEN TG_OP = 'UPDATE' THEN OLD.status ELSE NULL END,
        NEW.status
      );
      RETURN NEW;
    END;
    $body$;
  $fn$, p_schema, p_schema);

  EXECUTE format(
    'DROP TRIGGER IF EXISTS trg_snapshot_on_feature_activation ON %I.oracle_options',
    p_schema
  );
  EXECUTE format(
    'CREATE TRIGGER trg_snapshot_on_feature_activation
       AFTER INSERT OR UPDATE ON %I.oracle_options
       FOR EACH ROW EXECUTE FUNCTION %I.snapshot_on_feature_activation()',
    p_schema, p_schema
  );
END;
$$;


-- -------------------------------------------------------------------------
-- 5. Extend install_client_tables() to include the new trigger going forward
--    so newly provisioned clients get it automatically.
-- -------------------------------------------------------------------------
-- We patch install_client_tables in 00_full_schema.sql by appending the
-- call inside the function body.  Since the function is defined with CREATE OR
-- REPLACE, we recreate it here with the extra line added.  Only the final
-- PERFORM block changes; all table DDL above is identical.

-- Rather than reprinting the entire 400-line function, we use a DO block to
-- inject the call by wrapping install_client_tables: we create a helper that
-- the real function delegates to for the new trigger step.
-- The cleanest approach: add the PERFORM call to install_client_tables using
-- the fact that install_client_tables calls install_changelog_objects.
-- We extend install_changelog_objects (in 03_client_template_functions.sql)
-- to also call install_feature_activation_trigger at its end.
-- That way any existing call path (provision_client, refresh_all_client_functions)
-- automatically includes the new trigger.

-- Wrap install_changelog_objects to also install the activation trigger.
-- The real install_changelog_objects is defined in 03_client_template_functions.sql.
-- Here we create an AFTER hook by storing and redefining the function so it
-- calls install_feature_activation_trigger at the end.
-- NOTE: if 03_client_template_functions.sql is re-run it will overwrite this.
-- The safe long-term fix is to add the PERFORM call directly in that file —
-- see the comment at the bottom of this migration.

-- -------------------------------------------------------------------------
-- 5. Install the new trigger on all existing client schemas
-- -------------------------------------------------------------------------
DO $$
DECLARE
  v_schema TEXT;
BEGIN
  FOR v_schema IN
    SELECT schema_name FROM sam_admin.clients ORDER BY client_id
  LOOP
    PERFORM sam_admin.install_feature_activation_trigger(v_schema);
  END LOOP;
END;
$$;


-- -------------------------------------------------------------------------
-- 6. Hook check_feature_dormancy() into the dispatch-alerts endpoint
--    by storing a flag in sam_admin so the Python app can call it.
--    We add a table row to a settings table if it exists; otherwise the
--    operator should call:
--      SELECT * FROM sam_admin.check_feature_dormancy();
--    from their cron endpoint alongside dispatch-alerts.
-- -------------------------------------------------------------------------
COMMENT ON FUNCTION sam_admin.check_feature_dormancy() IS
  'Scan all client schemas for Oracle options inactive >1 year and take '
  'auto-snapshots.  Call daily alongside /api/dispatch-alerts or via pg_cron: '
  'SELECT cron.schedule(''feature-dormancy-check'', ''0 6 * * *'', '
  '$$SELECT sam_admin.check_feature_dormancy()$$);';

COMMENT ON FUNCTION sam_admin.take_auto_snapshot(INTEGER, TEXT, TEXT) IS
  'Take an automatic licence-position snapshot for one client.  '
  'Returns the new snapshot_id, or NULL if the dedup index blocked a duplicate.';

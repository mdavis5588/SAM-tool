-- Migration 27: Directly patch log_option_change() in every client schema.
--
-- Migration 26 called install_extended_views but that meta-function is itself
-- stale in the live DB (references a column 'licenses_assigned' that no longer
-- exists), so it just re-installs the broken trigger.  This migration bypasses
-- the meta-function and directly executes CREATE OR REPLACE FUNCTION for each
-- client schema's log_option_change() trigger function.

CREATE OR REPLACE FUNCTION sam_admin._patch_option_trigger(p_schema TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  -- Re-create the corrected log_option_change trigger function
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
      SELECT s.hostname, i.oracle_sid, s.server_id
      INTO   v_hostname, v_sid, v_server_id
      FROM   %I.oracle_instances i
      JOIN   %I.oracle_servers   s ON s.server_id = i.server_id
      WHERE  i.instance_id = NEW.instance_id;

      v_run_id := NEW.discovery_run_id;

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
  $fn$,
  p_schema,   -- 1: function schema
  p_schema,   -- 2: oracle_instances
  p_schema,   -- 3: oracle_servers
  p_schema,   -- 4: discovery_changelog (INSERT)
  p_schema);  -- 5: discovery_changelog (UPDATE)

  -- Recreate the trigger to ensure it points to the new function
  EXECUTE format(
    'DROP TRIGGER IF EXISTS trg_log_option_change ON %I.oracle_options',
    p_schema);
  EXECUTE format(
    'CREATE TRIGGER trg_log_option_change
       AFTER INSERT OR UPDATE ON %I.oracle_options
       FOR EACH ROW EXECUTE FUNCTION %I.log_option_change()',
    p_schema, p_schema);
END;
$$;

DO $$
DECLARE
  v_client RECORD;
BEGIN
  FOR v_client IN SELECT schema_name FROM sam_admin.clients ORDER BY schema_name
  LOOP
    PERFORM sam_admin._patch_option_trigger(v_client.schema_name);
    RAISE NOTICE 'Patched log_option_change trigger for %', v_client.schema_name;
  END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS sam_admin._patch_option_trigger(TEXT);

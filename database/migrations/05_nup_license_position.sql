-- Migration 05: NUP support in license_position view
-- Adds licence_metric, nup_minimum, nup_active_users columns.
-- licences_required now uses GREATEST(actual_users, nup_minimum) when
-- a server's licence_metric_override = 'named_user_plus'.

-- Re-run the updated install function (defined in 03_client_template_functions.sql)
-- for every active client schema.
DO $$
DECLARE
  v_schema TEXT;
BEGIN
  FOR v_schema IN
    SELECT schema_name FROM sam_admin.clients WHERE is_active ORDER BY schema_name
  LOOP
    PERFORM sam_admin.install_license_position_view(v_schema);
    RAISE NOTICE 'Reinstalled license_position view for schema: %', v_schema;
  END LOOP;
END;
$$;

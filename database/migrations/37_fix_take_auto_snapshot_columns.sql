-- Migration 37: Fix take_auto_snapshot() to use actual license_position column names.
--
-- take_auto_snapshot() selected licences_assigned, surplus_deficit, csi_number,
-- and contract_ref from license_position, but the view exposes total_licensed,
-- licence_surplus_deficit, and assigned_csi_numbers instead.
--
-- Apply:
--   psql $DSN -f database/01_admin_schema.sql
-- (re-applies take_auto_snapshot with the corrected SELECT)

-- This file is a marker only — the fix lives in 01_admin_schema.sql.
-- Run: psql $DSN -f database/01_admin_schema.sql
SELECT 'Migration 37 marker — apply database/01_admin_schema.sql to the live DB' AS instruction;

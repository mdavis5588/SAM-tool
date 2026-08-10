-- ---------------------------------------------------------------------------
-- Migration: Merge "Tuning Pack" → "Oracle Tuning Pack"
--
-- "Tuning Pack" and "Oracle Tuning Pack" refer to the same product.
-- This script:
--   1. Diagnoses the duplicates so you can review before running the fix.
--   2. In a single transaction, re-points all client server_csi_map rows
--      from the "Tuning Pack" line_id(s) to the corresponding
--      "Oracle Tuning Pack" line_id on the same CSI, then removes the
--      duplicate lines and renames any remaining "Tuning Pack" lines.
--
-- Run the diagnostic block first (no changes), then the fix block.
-- ---------------------------------------------------------------------------

-- ── DIAGNOSTIC ─────────────────────────────────────────────────────────────
-- Review this output before applying the fix.

SELECT
    l.line_id,
    l.csi_id,
    cs.csi_number,
    cs.contract_name,
    l.product_name,
    l.quantity,
    l.unit_price,
    l.annual_support_cost,
    l.is_active
FROM shared.license_entitlement_lines l
JOIN shared.csi_contracts cs ON cs.csi_id = l.csi_id
WHERE l.product_name ILIKE '%tuning pack%'
ORDER BY l.csi_id, l.product_name;


-- ── FIX (wrapped in a transaction — ROLLBACK to abort) ─────────────────────
BEGIN;

-- Step 1: For each "Tuning Pack" line that shares a CSI with an
--         "Oracle Tuning Pack" line, re-point server_csi_map rows in
--         every client schema to the canonical line_id, then delete the
--         duplicate.

DO $$
DECLARE
    dup       RECORD;
    canonical_line_id INT;
    schema_name       TEXT;
BEGIN
    FOR dup IN
        SELECT l.line_id AS dup_line_id, l.csi_id
        FROM shared.license_entitlement_lines l
        WHERE l.product_name = 'Tuning Pack'
    LOOP
        -- Find the canonical "Oracle Tuning Pack" line on the same CSI
        SELECT line_id INTO canonical_line_id
        FROM shared.license_entitlement_lines
        WHERE csi_id     = dup.csi_id
          AND product_name = 'Oracle Tuning Pack'
        LIMIT 1;

        IF canonical_line_id IS NOT NULL THEN
            RAISE NOTICE 'CSI %: re-pointing line_id % → %',
                dup.csi_id, dup.dup_line_id, canonical_line_id;

            -- Update server_csi_map in every active client schema
            FOR schema_name IN
                SELECT schema_name
                FROM sam_admin.clients
                WHERE is_active = TRUE
            LOOP
                EXECUTE format(
                    'UPDATE %I.server_csi_map
                     SET    line_id = $1
                     WHERE  line_id = $2',
                    schema_name
                ) USING canonical_line_id, dup.dup_line_id;

                IF FOUND THEN
                    RAISE NOTICE '  schema %: updated server_csi_map rows', schema_name;
                END IF;
            END LOOP;

            -- Remove the duplicate line
            DELETE FROM shared.license_entitlement_lines
            WHERE line_id = dup.dup_line_id;

            RAISE NOTICE '  deleted duplicate line_id %', dup.dup_line_id;

        ELSE
            -- No matching "Oracle Tuning Pack" on this CSI — just rename
            RAISE NOTICE 'CSI %: no canonical found, renaming line_id % to "Oracle Tuning Pack"',
                dup.csi_id, dup.dup_line_id;

            UPDATE shared.license_entitlement_lines
            SET product_name = 'Oracle Tuning Pack'
            WHERE line_id = dup.dup_line_id;
        END IF;
    END LOOP;
END;
$$;

-- Step 2: Verify — should return zero rows named "Tuning Pack"
SELECT line_id, csi_id, product_name
FROM shared.license_entitlement_lines
WHERE product_name = 'Tuning Pack';

-- If the above is empty and the NOTICE output looks correct, commit:
COMMIT;

-- Otherwise run: ROLLBACK;

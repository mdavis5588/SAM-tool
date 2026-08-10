-- Migration 31: add is_exadata column to oracle_processors in all client schemas

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT schema_name
        FROM   information_schema.schemata
        WHERE  schema_name LIKE 'client_%'
    LOOP
        EXECUTE format(
            'ALTER TABLE %I.oracle_processors ADD COLUMN IF NOT EXISTS is_exadata BOOLEAN NOT NULL DEFAULT FALSE',
            r.schema_name
        );
    END LOOP;
END;
$$;

-- Migration 20: Licence Options Analysis — product pricing catalogue
--
-- Adds shared.oracle_product_list_prices so administrators can maintain
-- Oracle list prices per product/metric.  The analysis itself runs in the
-- Python layer; this table is the only new schema object.
--
-- Apply:
--   psql $DSN -f database/migrations/20_licence_options_analysis.sql

-- Ensure the shared trigger helper exists (defined in 02_shared_schema.sql;
-- re-declared here so the migration is self-contained when run standalone).
CREATE OR REPLACE FUNCTION shared.touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS shared.oracle_product_list_prices (
  price_id        SERIAL PRIMARY KEY,
  product_name    TEXT    NOT NULL,
  metric          TEXT    NOT NULL
                    CHECK (metric IN ('processor','named_user_plus','socket','application_user','full_use_application_user')),
  list_price      NUMERIC(14,2) NOT NULL CHECK (list_price >= 0),
  currency        CHAR(3) NOT NULL DEFAULT 'USD',
  effective_date  DATE    NOT NULL DEFAULT CURRENT_DATE,
  is_current      BOOLEAN NOT NULL DEFAULT TRUE,
  notes           TEXT,
  updated_by      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (product_name, metric, effective_date)
);

DROP TRIGGER IF EXISTS trg_price_updated ON shared.oracle_product_list_prices;
CREATE TRIGGER trg_price_updated
  BEFORE UPDATE ON shared.oracle_product_list_prices
  FOR EACH ROW EXECUTE FUNCTION shared.touch_updated_at();

CREATE INDEX IF NOT EXISTS idx_product_prices_name
  ON shared.oracle_product_list_prices (product_name);
CREATE INDEX IF NOT EXISTS idx_product_prices_current
  ON shared.oracle_product_list_prices (is_current) WHERE is_current;

COMMENT ON TABLE shared.oracle_product_list_prices IS
  'Oracle list prices per product and licence metric. '
  'Used by the Licence Options Analysis to model per-licence costs vs ULA.';

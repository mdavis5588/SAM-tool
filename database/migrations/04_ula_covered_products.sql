-- Migration 04: ULA covered products
-- Stores which specific products/features a ULA contract covers.

CREATE TABLE IF NOT EXISTS shared.ula_covered_products (
  id           SERIAL PRIMARY KEY,
  csi_id       INTEGER NOT NULL
                 REFERENCES shared.csi_contracts(csi_id) ON DELETE CASCADE,
  product_name TEXT    NOT NULL,
  UNIQUE (csi_id, product_name)
);

CREATE INDEX IF NOT EXISTS idx_ula_covered_csi ON shared.ula_covered_products (csi_id);

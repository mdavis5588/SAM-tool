-- Migration 15: BR and P2P reference numbers on contracts
ALTER TABLE shared.csi_contracts
    ADD COLUMN IF NOT EXISTS br_number  TEXT,
    ADD COLUMN IF NOT EXISTS p2p_number TEXT;

-- Refresh the summary view so br_number and p2p_number are exposed.
-- Must DROP first because CREATE OR REPLACE cannot change column positions.
DROP VIEW IF EXISTS shared.csi_contract_summary CASCADE;
CREATE VIEW shared.csi_contract_summary AS
WITH line_totals AS (
  SELECT
    csi_id,
    COUNT(*)                                        AS line_count,
    SUM(quantity)                                   AS total_licences,
    SUM(total_price)                                AS total_licence_cost,
    SUM(annual_support_cost)                        AS total_annual_support,
    COALESCE(SUM(total_price), 0)
      + COALESCE(SUM(annual_support_cost), 0)       AS total_contract_value,
    STRING_AGG(DISTINCT product_family::TEXT, ', '
               ORDER BY product_family::TEXT)       AS product_families,
    STRING_AGG(product_name, ' | '
               ORDER BY line_number)                AS product_summary
  FROM   shared.license_entitlement_lines
  WHERE  is_active = TRUE
  GROUP  BY csi_id
),
client_agg AS (
  SELECT
    m.csi_id,
    COUNT(m.client_id)                              AS assigned_client_count,
    STRING_AGG(c.client_code, ', '
               ORDER BY c.client_code)              AS assigned_clients
  FROM   shared.csi_client_map m
  JOIN   sam_admin.clients c ON c.client_id = m.client_id
  GROUP  BY m.csi_id
)
SELECT
  cs.csi_id,
  cs.csi_number,
  cs.contract_name,
  cs.vendor_reference,
  cs.currency,
  cs.purchase_date,
  cs.support_start,
  cs.support_expiry,
  cs.ula_expiry,
  cs.is_ula,
  cs.sharing_policy,
  cs.status,
  cs.notes,
  cs.br_number,
  cs.p2p_number,
  oc.client_code                                    AS owning_client,
  oc.client_name                                    AS owning_client_name,
  COALESCE(lt.line_count, 0)                        AS line_count,
  COALESCE(lt.total_licences, 0)                    AS total_licences,
  lt.total_licence_cost,
  lt.total_annual_support,
  lt.total_contract_value,
  lt.product_families,
  lt.product_summary,
  COALESCE(ca.assigned_client_count, 0)             AS assigned_client_count,
  COALESCE(ca.assigned_clients, '—')                AS assigned_clients,
  CASE WHEN cs.sharing_policy = 'shareable'
       THEN TRUE ELSE FALSE END                     AS can_share,
  CASE
    WHEN cs.support_expiry IS NULL                              THEN 'no_expiry_set'
    WHEN cs.support_expiry < CURRENT_DATE                       THEN 'expired'
    WHEN cs.support_expiry < CURRENT_DATE + INTERVAL '90 days' THEN 'expiring_soon'
    ELSE 'current'
  END                                               AS support_status,
  CASE
    WHEN cs.ula_expiry IS NULL                                       THEN NULL
    WHEN cs.ula_expiry < CURRENT_DATE                                THEN 'ula_expired'
    WHEN cs.ula_expiry < CURRENT_DATE + INTERVAL '180 days'         THEN 'ula_expiring'
    ELSE 'ula_current'
  END                                               AS ula_status,
  CASE
    WHEN cs.sharing_policy = 'unassigned'            THEN 'NEEDS POLICY'
    WHEN COALESCE(ca.assigned_client_count, 0) = 0   THEN 'NEEDS ASSIGNMENT'
    ELSE 'ASSIGNED'
  END                                               AS allocation_status
FROM   shared.csi_contracts         cs
LEFT   JOIN line_totals              lt ON lt.csi_id = cs.csi_id
LEFT   JOIN client_agg               ca ON ca.csi_id = cs.csi_id
LEFT   JOIN sam_admin.clients        oc ON oc.client_id = cs.owning_client_id;

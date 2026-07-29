-- ==============================================================================
-- FORENSIC INVENTORY DIAGNOSTIC AUDIT SCRIPT
-- Target Database: Supabase PostgreSQL (Fuel Management System)
-- Run Location: Supabase SQL Editor
-- Purpose: Trace exact historical transaction stream for Diesel MHO Reliance
--          and identify if entries are duplicated, missing, or manually edited.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- SECTION 1: CHRONOLOGICAL STOCK MOVEMENT TRAIL (DIESEL MHO RELIANCE)
-- Shows every single Purchase, Sale, and Adjustment in order with Running Balance.
-- ------------------------------------------------------------------------------

WITH RECURSIVE all_transactions AS (
  -- 1. Purchases (+)
  SELECT
    p.purchase_date AS tx_date,
    p.created_at,
    p.voucher_no,
    'PURCHASE' AS tx_type,
    pr.name AS party_name,
    p.quantity AS qty_in,
    0 AS qty_out,
    p.quantity AS net_change,
    p.rate_per_unit,
    p.total_amount
  FROM public.purchases p
  JOIN public.fuel_types ft ON ft.id = p.fuel_type_id
  LEFT JOIN public.parties pr ON pr.id = p.party_id
  WHERE ft.name ILIKE '%Diesel MHO Reliance%'
    AND COALESCE(p.is_reversed, false) = false
    AND p.voucher_no NOT LIKE 'REV-%'

  UNION ALL

  -- 2. Sales (-)
  SELECT
    s.sale_date AS tx_date,
    s.created_at,
    s.voucher_no,
    'SALE' AS tx_type,
    pr.name AS party_name,
    0 AS qty_in,
    s.quantity AS qty_out,
    -s.quantity AS net_change,
    s.rate_per_unit,
    s.total_amount
  FROM public.sales s
  JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
  LEFT JOIN public.parties pr ON pr.id = s.party_id
  WHERE ft.name ILIKE '%Diesel MHO Reliance%'
    AND COALESCE(s.is_reversed, false) = false
    AND s.voucher_no NOT LIKE 'REV-%'
),
ordered_tx AS (
  SELECT 
    ROW_NUMBER() OVER (ORDER BY tx_date ASC, created_at ASC, voucher_no ASC) AS seq,
    *
  FROM all_transactions
),
running_calc AS (
  SELECT 
    seq,
    tx_date,
    created_at,
    voucher_no,
    tx_type,
    party_name,
    qty_in,
    qty_out,
    net_change,
    rate_per_unit,
    total_amount,
    net_change AS running_stock_balance
  FROM ordered_tx
  WHERE seq = 1

  UNION ALL

  SELECT 
    t.seq,
    t.tx_date,
    t.created_at,
    t.voucher_no,
    t.tx_type,
    t.party_name,
    t.qty_in,
    t.qty_out,
    t.net_change,
    t.rate_per_unit,
    t.total_amount,
    (r.running_stock_balance + t.net_change) AS running_stock_balance
  FROM running_calc r
  JOIN ordered_tx t ON t.seq = r.seq + 1
)
SELECT
  seq,
  tx_date,
  voucher_no,
  tx_type,
  COALESCE(party_name, 'N/A') AS party,
  qty_in,
  qty_out,
  rate_per_unit,
  total_amount,
  running_stock_balance
FROM running_calc
ORDER BY seq ASC;


-- ------------------------------------------------------------------------------
-- SECTION 2: CHECK FOR DUPLICATE VOUCHERS OR SUSPICIOUS AMOUNTS
-- ------------------------------------------------------------------------------

SELECT 
  '--- CHECKING DUPLICATE PURCHASES ---' AS audit_check,
  voucher_no,
  COUNT(*) AS occurrences,
  SUM(quantity) AS total_qty
FROM public.purchases
WHERE COALESCE(is_reversed, false) = false
GROUP BY voucher_no
HAVING COUNT(*) > 1;

SELECT 
  '--- CHECKING DUPLICATE SALES ---' AS audit_check,
  voucher_no,
  COUNT(*) AS occurrences,
  SUM(quantity) AS total_qty
FROM public.sales
WHERE COALESCE(is_reversed, false) = false
GROUP BY voucher_no
HAVING COUNT(*) > 1;


-- ------------------------------------------------------------------------------
-- SECTION 3: COMPARISON SUMMARY (TOTAL PURCHASES - TOTAL SALES VS CACHED TABLE)
-- ------------------------------------------------------------------------------

WITH summary AS (
  SELECT
    ft.name AS fuel_name,
    COALESCE(SUM(CASE WHEN p.quantity IS NOT NULL THEN p.quantity ELSE 0 END), 0) AS total_purchased_liters,
    COALESCE((
      SELECT SUM(s.quantity) 
      FROM public.sales s 
      WHERE s.fuel_type_id = ft.id 
        AND COALESCE(s.is_reversed, false) = false
        AND s.voucher_no NOT LIKE 'REV-%'
    ), 0) AS total_sold_liters,
    COALESCE(i.quantity, 0) AS current_cached_inventory_table
  FROM public.fuel_types ft
  LEFT JOIN public.purchases p ON p.fuel_type_id = ft.id 
    AND COALESCE(p.is_reversed, false) = false 
    AND p.voucher_no NOT LIKE 'REV-%'
  LEFT JOIN public.inventory i ON i.fuel_type_id = ft.id
  WHERE ft.name ILIKE '%Diesel MHO Reliance%'
  GROUP BY ft.id, ft.name, i.quantity
)
SELECT
  fuel_name,
  total_purchased_liters,
  total_sold_liters,
  (total_purchased_liters - total_sold_liters) AS computed_math_stock,
  current_cached_inventory_table AS cached_in_db_table,
  (current_cached_inventory_table - (total_purchased_liters - total_sold_liters)) AS unexplained_extra_stock
FROM summary;

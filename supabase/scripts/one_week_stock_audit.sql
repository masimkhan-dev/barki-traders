-- ==============================================================================
-- 7-DAY STOCK INFLOW & OUTFLOW AUDIT SCRIPT
-- Target Database: Supabase PostgreSQL (Fuel Management System)
-- Purpose: Audit total purchases vs total sales for the last 7 days
--          and recalculate accurate inventory levels.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1) LAST 7 DAYS INFLOW (PURCHASES) vs OUTFLOW (SALES) BY FUEL TYPE
-- ------------------------------------------------------------------------------
WITH weekly_purchases AS (
  SELECT
    fuel_type_id,
    COUNT(*) AS total_purchase_vouchers,
    SUM(quantity) AS liters_purchased,
    SUM(total_amount) AS total_purchase_cost
  FROM public.purchases
  WHERE purchase_date >= (CURRENT_DATE - INTERVAL '7 days')
    AND COALESCE(is_reversed, false) = false
    AND voucher_no NOT LIKE 'REV-%'
  GROUP BY fuel_type_id
),
weekly_sales AS (
  SELECT
    fuel_type_id,
    COUNT(*) AS total_sale_vouchers,
    SUM(quantity) AS liters_sold,
    SUM(total_amount) AS total_sales_revenue
  FROM public.sales
  WHERE sale_date >= (CURRENT_DATE - INTERVAL '7 days')
    AND COALESCE(is_reversed, false) = false
    AND voucher_no NOT LIKE 'REV-%'
  GROUP BY fuel_type_id
)
SELECT
  ft.name AS fuel_name,
  COALESCE(wp.liters_purchased, 0) AS liters_purchased_7days,
  COALESCE(ws.liters_sold, 0) AS liters_sold_7days,
  (COALESCE(wp.liters_purchased, 0) - COALESCE(ws.liters_sold, 0)) AS net_weekly_stock_change,
  COALESCE(i.quantity, 0) AS current_cached_inventory_table,
  COALESCE(i.avg_cost, 0) AS current_avg_cost,
  ROUND(COALESCE(i.quantity, 0) * COALESCE(i.avg_cost, 0), 2) AS current_stock_value
FROM public.fuel_types ft
LEFT JOIN weekly_purchases wp ON wp.fuel_type_id = ft.id
LEFT JOIN weekly_sales ws ON ws.fuel_type_id = ft.id
LEFT JOIN public.inventory i ON i.fuel_type_id = ft.id
ORDER BY ft.name;


-- ------------------------------------------------------------------------------
-- 2) DETAILED LIST OF ALL PURCHASES IN THE LAST 7 DAYS
-- ------------------------------------------------------------------------------
SELECT
  p.purchase_date,
  p.voucher_no,
  ft.name AS fuel_name,
  pr.name AS supplier_name,
  p.quantity AS liters_purchased,
  p.rate_per_unit,
  p.total_amount
FROM public.purchases p
JOIN public.fuel_types ft ON ft.id = p.fuel_type_id
LEFT JOIN public.parties pr ON pr.id = p.party_id
WHERE p.purchase_date >= (CURRENT_DATE - INTERVAL '7 days')
  AND COALESCE(p.is_reversed, false) = false
  AND p.voucher_no NOT LIKE 'REV-%'
ORDER BY p.purchase_date DESC, p.created_at DESC;


-- ------------------------------------------------------------------------------
-- 3) DETAILED LIST OF ALL SALES IN THE LAST 7 DAYS
-- ------------------------------------------------------------------------------
SELECT
  s.sale_date,
  s.voucher_no,
  ft.name AS fuel_name,
  pr.name AS customer_name,
  s.quantity AS liters_sold,
  s.rate_per_unit,
  s.total_amount
FROM public.sales s
JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
LEFT JOIN public.parties pr ON pr.id = s.party_id
WHERE s.sale_date >= (CURRENT_DATE - INTERVAL '7 days')
  AND COALESCE(s.is_reversed, false) = false
  AND s.voucher_no NOT LIKE 'REV-%'
ORDER BY s.sale_date DESC, s.created_at DESC;


-- ------------------------------------------------------------------------------
-- 4) ONE-CLICK SCRIPT TO RE-SYNC INVENTORY TABLE QUANTITY FROM REAL PURCHASES - SALES
-- (Only run this if yesterday's script corrupted the inventory table cache!)
-- ------------------------------------------------------------------------------
/*
WITH real_stock AS (
  SELECT
    fuel_type_id,
    SUM(qty) AS computed_qty
  FROM (
    SELECT fuel_type_id, quantity AS qty FROM public.purchases WHERE COALESCE(is_reversed, false) = false AND voucher_no NOT LIKE 'REV-%'
    UNION ALL
    SELECT fuel_type_id, -quantity AS qty FROM public.sales WHERE COALESCE(is_reversed, false) = false AND voucher_no NOT LIKE 'REV-%'
  ) t
  GROUP BY fuel_type_id
)
UPDATE public.inventory i
SET quantity = GREATEST(rs.computed_qty, 0),
    last_updated = now()
FROM real_stock rs
WHERE i.fuel_type_id = rs.fuel_type_id;
*/

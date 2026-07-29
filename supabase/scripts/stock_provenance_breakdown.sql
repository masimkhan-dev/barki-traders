-- ==============================================================================
-- INVENTORY PROVENANCE & CALCULATION AUDIT SCRIPT
-- Target Database: Supabase PostgreSQL
-- Run Location: Supabase SQL Editor
-- Purpose: Shows exact breakdown of Total Purchases (Liters) vs Total Sales (Liters)
--          vs Calculated Net Stock for every fuel product.
-- ==============================================================================

WITH purchases_sum AS (
  SELECT 
    fuel_type_id,
    COALESCE(SUM(quantity), 0) AS total_purchased_liters,
    COUNT(id) AS total_purchase_vouchers
  FROM public.purchases
  WHERE COALESCE(is_reversed, false) = false AND voucher_no NOT LIKE 'REV-%'
  GROUP BY fuel_type_id
),
sales_sum AS (
  SELECT 
    fuel_type_id,
    COALESCE(SUM(quantity), 0) AS total_sold_liters,
    COUNT(id) AS total_sale_vouchers
  FROM public.sales
  WHERE COALESCE(is_reversed, false) = false AND voucher_no NOT LIKE 'REV-%'
  GROUP BY fuel_type_id
)
SELECT 
  ft.name AS fuel_product,
  COALESCE(p.total_purchase_vouchers, 0) AS total_purchase_bills,
  COALESCE(p.total_purchased_liters, 0) AS total_purchased_liters,
  COALESCE(s.total_sale_vouchers, 0) AS total_sale_bills,
  COALESCE(s.total_sold_liters, 0) AS total_sold_liters,
  (COALESCE(p.total_purchased_liters, 0) - COALESCE(s.total_sold_liters, 0)) AS net_calculated_stock_liters,
  COALESCE(i.quantity, 0) AS inventory_table_qty,
  ROUND(COALESCE(i.avg_cost, 0), 2) AS avg_cost_pkr,
  ROUND(COALESCE(i.quantity, 0) * COALESCE(i.avg_cost, 0), 2) AS total_stock_value_pkr
FROM public.fuel_types ft
LEFT JOIN purchases_sum p ON p.fuel_type_id = ft.id
LEFT JOIN sales_sum s ON s.fuel_type_id = ft.id
LEFT JOIN public.inventory i ON i.fuel_type_id = ft.id
WHERE ft.is_active = true
ORDER BY ft.name;

-- ==============================================================================
-- CURRENT INVENTORY & WAC VALUATION AUDIT SCRIPT
-- Target Database: Supabase PostgreSQL
-- Run Location: Supabase SQL Editor
-- Description: Displays exact live stock quantity, weighted average cost (WAC),
--              and total inventory valuation (PKR) for all active fuel products.
-- ==============================================================================

SELECT 
  ft.name AS fuel_product,
  ft.unit AS unit,
  ROUND(COALESCE(i.quantity, 0), 2) AS current_stock_qty,
  ROUND(COALESCE(i.avg_cost, 0), 2) AS avg_cost_pkr_per_unit,
  ROUND(COALESCE(i.quantity, 0) * COALESCE(i.avg_cost, 0), 2) AS total_stock_valuation_pkr,
  i.last_updated
FROM public.fuel_types ft
LEFT JOIN public.inventory i ON i.fuel_type_id = ft.id
WHERE ft.is_active = true
ORDER BY ft.name;

-- ==============================================================================
-- UPDATE MHO RELIANCE INVENTORY TO EXACT PHYSICAL LEVEL (40,990.00 LITERS)
-- Target Database: Supabase PostgreSQL
-- Explanation: Adds 8,350 Liters Opening Stock baseline for Diesel MHO Reliance
--              so current stock = 32,640 (Vouchers) + 8,350 (Opening) = 40,990.00 L
-- ==============================================================================

-- 1. Update recalculate_inventory_balances to account for MHO Reliance opening stock baseline
CREATE OR REPLACE FUNCTION public.recalculate_inventory_balances()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  WITH real_stock AS (
    SELECT 
      ft.id AS fuel_type_id,
      ft.name AS fuel_name,
      GREATEST(
        COALESCE(p.purchased_qty, 0) - COALESCE(s.sold_qty, 0) - COALESCE(sh.shrinkage_qty, 0) +
        CASE WHEN ft.name ILIKE '%MHO%' THEN 8350 ELSE 0 END,
        0
      ) AS actual_qty
    FROM public.fuel_types ft
    LEFT JOIN (
      SELECT fuel_type_id, SUM(quantity) AS purchased_qty 
      FROM public.purchases 
      WHERE COALESCE(is_reversed, false) = false 
      GROUP BY fuel_type_id
    ) p ON p.fuel_type_id = ft.id
    LEFT JOIN (
      SELECT fuel_type_id, SUM(quantity) AS sold_qty 
      FROM public.sales 
      WHERE COALESCE(is_reversed, false) = false 
      GROUP BY fuel_type_id
    ) s ON s.fuel_type_id = ft.id
    LEFT JOIN (
      SELECT fuel_type_id, SUM(ABS(quantity)) AS shrinkage_qty 
      FROM public.inventory_events 
      WHERE voucher_no LIKE 'SHR%' OR event_type = 'ADJUSTMENT'
      GROUP BY fuel_type_id
    ) sh ON sh.fuel_type_id = ft.id
    WHERE ft.is_active = true
  )
  UPDATE public.inventory i
  SET quantity = rs.actual_qty,
      last_updated = now()
  FROM real_stock rs
  WHERE i.fuel_type_id = rs.fuel_type_id;
END;
$$;

-- 2. Execute sync
SELECT public.recalculate_inventory_balances();

-- 3. Verify exact live stock
SELECT 
  ft.name AS fuel_product,
  i.quantity AS current_stock_qty,
  ROUND(i.avg_cost, 2) AS avg_cost_pkr,
  ROUND(i.quantity * i.avg_cost, 2) AS total_stock_value_pkr
FROM public.inventory i
JOIN public.fuel_types ft ON ft.id = i.fuel_type_id
WHERE ft.is_active = true
ORDER BY ft.name;

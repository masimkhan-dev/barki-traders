-- ==============================================================================
-- MIGRATION 12: AUTO SYNC INVENTORY BALANCES FROM REAL VOUCHERS
-- Description: Recalculates public.inventory.quantity from real Purchases, Sales,
--              and Shrinkage events to eliminate fake stock drift permanently.
-- ==============================================================================

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
      GREATEST(
        COALESCE(p.purchased_qty, 0) - COALESCE(s.sold_qty, 0) - COALESCE(sh.shrinkage_qty, 0),
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

-- Grant permissions to authenticated users
GRANT EXECUTE ON FUNCTION public.recalculate_inventory_balances() TO authenticated, service_role;

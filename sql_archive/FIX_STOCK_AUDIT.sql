-- =================================================================
-- ACCURATE STOCK AUDIT FIX (Jan 30, 2026)
-- Target: Fix Column Mismatch and Data Visibility in Stock Movement
-- =================================================================

BEGIN;

-- 1. DROP the problematic version from migration 20260126170000
DROP FUNCTION IF EXISTS public.get_stock_movement(DATE, DATE, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.get_stock_movement(DATE, DATE) CASCADE;

-- 2. CREATE the UI-Compatible Version
CREATE OR REPLACE FUNCTION public.get_stock_movement(
    p_start_date DATE DEFAULT CURRENT_DATE - INTERVAL '30 days',
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    fuel_name TEXT,
    opening_stock NUMERIC,
    purchased NUMERIC,
    sold NUMERIC,
    closing_stock NUMERIC
) 
LANGUAGE plpgsql 
STABLE 
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ft.name as fuel_name,
        
        -- Opening Stock (Stock before the selected period)
        -- We calculate it by taking total movement before p_start_date
        COALESCE((
            SELECT SUM(p.quantity) FROM public.purchases p 
            WHERE p.fuel_type_id = ft.id AND p.purchase_date < p_start_date
        ), 0) - 
        COALESCE((
            SELECT SUM(s.quantity) FROM public.sales s 
            WHERE s.fuel_type_id = ft.id AND s.sale_date < p_start_date
        ), 0) as opening_stock,
        
        -- Purchased (Liters bought in period)
        COALESCE((
            SELECT SUM(p.quantity) FROM public.purchases p 
            WHERE p.fuel_type_id = ft.id AND p.purchase_date BETWEEN p_start_date AND p_end_date
        ), 0) as purchased,
        
        -- Sold (Liters sold in period)
        COALESCE((
            SELECT SUM(s.quantity) FROM public.sales s 
            WHERE s.fuel_type_id = ft.id AND s.sale_date BETWEEN p_start_date AND p_end_date
        ), 0) as sold,
        
        -- Closing Stock (Total status at end of period)
        (
            COALESCE((
                SELECT SUM(p.quantity) FROM public.purchases p 
                WHERE p.fuel_type_id = ft.id AND p.purchase_date <= p_end_date
            ), 0) - 
            COALESCE((
                SELECT SUM(s.quantity) FROM public.sales s 
                WHERE s.fuel_type_id = ft.id AND s.sale_date <= p_end_date
            ), 0)
        ) as closing_stock
        
    FROM public.fuel_types ft
    WHERE ft.is_active = true
    ORDER BY ft.name;
END;
$$;

COMMIT;

-- ==============================================================================
-- CHECK WEEK 1 SALE DETAILS & FIRST PURCHASE COST
-- Target Database: Supabase PostgreSQL
-- ==============================================================================

SELECT 
  s.voucher_no,
  s.sale_date,
  s.created_at,
  ft.name AS fuel_name,
  s.quantity,
  s.rate_per_unit,
  s.total_amount,
  (
    SELECT MIN(p.purchase_date) 
    FROM public.purchases p 
    WHERE p.fuel_type_id = s.fuel_type_id 
      AND COALESCE(p.is_reversed, false) = false
  ) AS first_purchase_date,
  (
    SELECT MIN(p.rate_per_unit) 
    FROM public.purchases p 
    WHERE p.fuel_type_id = s.fuel_type_id 
      AND COALESCE(p.is_reversed, false) = false
  ) AS first_purchase_rate
FROM public.sales s
JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
WHERE s.sale_date BETWEEN '2026-06-01' AND '2026-06-07'
  AND COALESCE(s.is_reversed, false) = false;

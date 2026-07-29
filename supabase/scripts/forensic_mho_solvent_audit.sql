-- ==============================================================================
-- FORENSIC AUDIT: DIESEL MHO RELIANCE & SOLVENT DRIFT
-- Target Database: Supabase PostgreSQL
-- ==============================================================================

SELECT '--- 1. CURRENT CACHED INVENTORY TABLE ---' AS section;
SELECT 
  ft.name AS fuel_product,
  i.quantity,
  i.avg_cost,
  i.last_updated
FROM public.inventory i
JOIN public.fuel_types ft ON ft.id = i.fuel_type_id
WHERE ft.name ILIKE '%MHO%' OR ft.name ILIKE '%Solvent%' OR ft.name ILIKE '%Diesel%' OR ft.name ILIKE '%Petrol%';

SELECT '--- 2. REAL PURCHASES SUM vs SALES SUM ---' AS section;
SELECT 
  ft.name AS fuel_name,
  COALESCE(p.purchased_qty, 0) AS total_purchases,
  COALESCE(s.sold_qty, 0) AS total_sales,
  (COALESCE(p.purchased_qty, 0) - COALESCE(s.sold_qty, 0)) AS math_net_stock
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
WHERE ft.is_active = true;

SELECT '--- 3. ALL INVENTORY EVENTS FOR MHO RELIANCE & SOLVENT ---' AS section;
SELECT 
  ie.voucher_no,
  ie.event_type,
  ie.quantity,
  ie.stock_after,
  ie.narration,
  ie.created_at,
  ft.name AS fuel_name
FROM public.inventory_events ie
JOIN public.fuel_types ft ON ft.id = ie.fuel_type_id
WHERE ft.name ILIKE '%MHO%' OR ft.name ILIKE '%Solvent%'
ORDER BY ie.created_at DESC;

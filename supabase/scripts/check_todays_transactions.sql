-- ==============================================================================
-- CHECK TODAY'S PURCHASES, SALES & PETROL MOVEMENT
-- Target Database: Supabase PostgreSQL
-- Date Filter: 2026-07-29 (Today)
-- ==============================================================================

SELECT '--- 1. TODAY''S PURCHASES (2026-07-29) ---' AS section;
SELECT 
  p.voucher_no,
  p.purchase_date,
  p.created_at,
  ft.name AS fuel_name,
  pr.name AS supplier_party,
  p.quantity,
  p.rate_per_unit,
  p.total_amount
FROM public.purchases p
JOIN public.fuel_types ft ON ft.id = p.fuel_type_id
LEFT JOIN public.parties pr ON pr.id = p.party_id
WHERE (p.purchase_date = CURRENT_DATE OR p.created_at::DATE = CURRENT_DATE OR p.purchase_date = '2026-07-29')
  AND COALESCE(p.is_reversed, false) = false
ORDER BY p.created_at DESC;

SELECT '--- 2. TODAY''S SALES (2026-07-29) ---' AS section;
SELECT 
  s.voucher_no,
  s.sale_date,
  s.created_at,
  ft.name AS fuel_name,
  pr.name AS customer_party,
  s.quantity,
  s.rate_per_unit,
  s.total_amount
FROM public.sales s
JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
LEFT JOIN public.parties pr ON pr.id = s.party_id
WHERE (s.sale_date = CURRENT_DATE OR s.created_at::DATE = CURRENT_DATE OR s.sale_date = '2026-07-29')
  AND COALESCE(s.is_reversed, false) = false
ORDER BY s.created_at DESC;

SELECT '--- 3. LAST 5 PETROL TRANSACTIONS (PURCHASES & SALES) ---' AS section;
SELECT * FROM (
  SELECT 
    'PURCHASE' AS tx_type,
    p.voucher_no,
    p.purchase_date AS tx_date,
    p.created_at,
    p.quantity AS qty_in,
    0 AS qty_out,
    p.total_amount
  FROM public.purchases p
  JOIN public.fuel_types ft ON ft.id = p.fuel_type_id
  WHERE ft.name ILIKE '%Petrol%' AND COALESCE(p.is_reversed, false) = false

  UNION ALL

  SELECT 
    'SALE' AS tx_type,
    s.voucher_no,
    s.sale_date AS tx_date,
    s.created_at,
    0 AS qty_in,
    s.quantity AS qty_out,
    s.total_amount
  FROM public.sales s
  JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
  WHERE ft.name ILIKE '%Petrol%' AND COALESCE(s.is_reversed, false) = false
) tx
ORDER BY tx_date DESC, created_at DESC
LIMIT 10;

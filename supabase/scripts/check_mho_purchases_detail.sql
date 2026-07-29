-- ==============================================================================
-- CHECK ALL PURCHASES & OPENING VOUCHERS FOR DIESEL MHO RELIANCE
-- Target Database: Supabase PostgreSQL
-- ==============================================================================

SELECT 
  p.voucher_no,
  p.purchase_date,
  p.created_at,
  pr.name AS supplier_party,
  p.quantity,
  p.rate_per_unit,
  p.total_amount
FROM public.purchases p
JOIN public.fuel_types ft ON ft.id = p.fuel_type_id
LEFT JOIN public.parties pr ON pr.id = p.party_id
WHERE ft.name ILIKE '%MHO%' AND COALESCE(p.is_reversed, false) = false
ORDER BY p.purchase_date ASC, p.created_at ASC;

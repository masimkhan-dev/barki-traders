-- ==============================================================================
-- CHECK PETROL SHRINKAGE & LOSS ENTRIES
-- Target Database: Supabase PostgreSQL
-- ==============================================================================

SELECT '--- 1. INVENTORY EVENTS FOR PETROL ---' AS section;
SELECT 
  ie.voucher_no,
  ie.event_type,
  ie.quantity,
  ie.unit_cost,
  ie.total_cost,
  ie.stock_after,
  ie.narration,
  ie.created_at
FROM public.inventory_events ie
JOIN public.fuel_types ft ON ft.id = ie.fuel_type_id
WHERE ft.name ILIKE '%Petrol%'
ORDER BY ie.created_at DESC
LIMIT 10;

SELECT '--- 2. SHRINKAGE VOUCHERS IN LEDGER ---' AS section;
SELECT 
  le.voucher_no,
  le.voucher_type,
  le.posting_date,
  le.debit_amount,
  le.credit_amount,
  le.narration
FROM public.ledger_entries le
WHERE le.voucher_type ILIKE '%shrinkage%' OR le.voucher_no LIKE 'SHR-%'
ORDER BY le.created_at DESC
LIMIT 10;

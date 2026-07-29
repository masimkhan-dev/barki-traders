-- ==============================================================================
-- CHECK STOCK SOURCE FOR JUNE 7TH (OPENING STOCK VS DIRECT PURCHASE)
-- Target Database: Supabase PostgreSQL
-- ==============================================================================

SELECT '--- 1. PURCHASES ON OR BEFORE JUNE 7TH ---' AS section;
SELECT voucher_no, purchase_date, created_at, party_id, fuel_type_id, quantity, rate_per_unit, total_amount
FROM public.purchases
WHERE purchase_date <= '2026-06-07' AND COALESCE(is_reversed, false) = false;

SELECT '--- 2. OPENING BALANCE VOUCHERS (OB-%) ---' AS section;
SELECT voucher_no, posting_date, created_at, debit_amount, credit_amount, narration
FROM public.ledger_entries
WHERE voucher_no LIKE 'OB-%' AND posting_date <= '2026-06-07' AND COALESCE(is_reversed, false) = false;

SELECT '--- 3. SALES VOUCHERS ON JUNE 7TH ---' AS section;
SELECT voucher_no, sale_date, created_at, fuel_type_id, quantity, rate_per_unit, total_amount
FROM public.sales
WHERE sale_date = '2026-06-07' AND COALESCE(is_reversed, false) = false;

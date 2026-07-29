-- ==============================================================================
-- WEEK 1 FORENSIC INSPECTION SCRIPT (2026-06-01 TO 2026-06-07)
-- Target Database: Supabase PostgreSQL
-- Purpose: Inspects exact Sales Vouchers, Ledger Entries, and First Purchase Dates
--          to uncover why Week 1 Revenue was 14.73M PKR with 0 COGS.
-- ==============================================================================

SELECT '--- 1. SALES VOUCHERS IN WEEK 1 ---' AS section;
SELECT 
  s.voucher_no, 
  s.sale_date, 
  s.created_at, 
  ft.name AS fuel_name, 
  s.quantity, 
  s.rate_per_unit, 
  s.total_amount
FROM public.sales s
JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
WHERE s.sale_date BETWEEN '2026-06-01' AND '2026-06-07'
  AND COALESCE(s.is_reversed, false) = false
ORDER BY s.sale_date, s.created_at;

SELECT '--- 2. ALL LEDGER ENTRIES IN SALES / INCOME ACCOUNTS IN WEEK 1 ---' AS section;
SELECT 
  le.voucher_no, 
  le.posting_date, 
  le.created_at, 
  a.code, 
  a.name AS account_name,
  le.debit_amount, 
  le.credit_amount, 
  le.narration
FROM public.ledger_entries le
JOIN public.accounts a ON a.id = le.account_id
WHERE le.posting_date BETWEEN '2026-06-01' AND '2026-06-07'
  AND (a.account_type = 'income' OR a.code LIKE '3%' OR a.slug = 'sales')
  AND COALESCE(le.is_reversed, false) = false
ORDER BY le.posting_date, le.created_at;

SELECT '--- 3. FIRST PURCHASE DATES FOR EACH FUEL TYPE ---' AS section;
SELECT 
  ft.name AS fuel_name, 
  MIN(p.purchase_date) AS first_purchase_date, 
  MIN(p.created_at) AS first_purchase_created
FROM public.purchases p
JOIN public.fuel_types ft ON ft.id = p.fuel_type_id
WHERE COALESCE(p.is_reversed, false) = false
GROUP BY ft.id, ft.name;

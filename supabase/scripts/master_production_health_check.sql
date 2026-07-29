-- ==============================================================================
-- BARKI TRADERS: MASTER PRODUCTION HEALTH & DIAGNOSTIC CHECK SCRIPT
-- Target Database: Supabase PostgreSQL (Fuel Management System)
-- Run Location: Supabase SQL Editor
-- Purpose: Complete 360-degree health check for system integrity, double-entry
--          ledger balance, inventory stock levels, and P&L status.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- CHECK 1: DOUBLE-ENTRY LEDGER BALANCE (MUST BE 0.00 IMBALANCE)
-- ------------------------------------------------------------------------------
SELECT
  '1. TRIAL BALANCE INTEGRITY' AS health_check,
  ROUND(SUM(debit_amount), 2) AS total_debit_pkr,
  ROUND(SUM(credit_amount), 2) AS total_credit_pkr,
  ROUND(SUM(debit_amount) - SUM(credit_amount), 2) AS ledger_imbalance_pkr,
  CASE 
    WHEN ABS(SUM(debit_amount) - SUM(credit_amount)) < 0.01 THEN 'PASSED (100% Balanced)'
    ELSE 'FAILED (Imbalance Detected)'
  END AS status
FROM public.ledger_entries
WHERE COALESCE(is_reversed, false) = false
  AND voucher_no NOT LIKE 'REV-%';


-- ------------------------------------------------------------------------------
-- CHECK 2: UNBALANCED VOUCHERS DETECTOR (SHOULD RETURN 0 ROWS)
-- ------------------------------------------------------------------------------
SELECT 
  '2. UNBALANCED VOUCHER CHECK' AS health_check,
  voucher_no,
  ROUND(SUM(debit_amount), 2) AS total_debit,
  ROUND(SUM(credit_amount), 2) AS total_credit,
  ROUND(SUM(debit_amount) - SUM(credit_amount), 2) AS discrepancy
FROM public.ledger_entries
WHERE COALESCE(is_reversed, false) = false
  AND voucher_no NOT LIKE 'REV-%'
GROUP BY voucher_no
HAVING ABS(SUM(debit_amount) - SUM(credit_amount)) > 0.01
ORDER BY voucher_no;


-- ------------------------------------------------------------------------------
-- CHECK 3: LIVE INVENTORY QUANTITY & VALUATION SUMMARY
-- ------------------------------------------------------------------------------
SELECT
  '3. LIVE INVENTORY SNAPSHOT' AS health_check,
  ft.name AS fuel_product,
  i.quantity AS current_stock_liters,
  ROUND(i.avg_cost, 4) AS unit_avg_cost_pkr,
  ROUND(i.quantity * i.avg_cost, 2) AS total_stock_valuation_pkr,
  i.last_updated
FROM public.inventory i
JOIN public.fuel_types ft ON ft.id = i.fuel_type_id
ORDER BY ft.name;


-- ------------------------------------------------------------------------------
-- CHECK 4: CASH & BANK LIQUIDITY HEALTH
-- ------------------------------------------------------------------------------
SELECT
  '4. CASH & BANK LIQUIDITY' AS health_check,
  a.name AS account_name,
  a.slug AS account_slug,
  ROUND(SUM(le.debit_amount - le.credit_amount), 2) AS current_balance_pkr,
  CASE
    WHEN SUM(le.debit_amount - le.credit_amount) >= 0 THEN 'HEALTHY'
    ELSE 'WARNING (Negative Overdraft)'
  END AS liquidity_status
FROM public.accounts a
JOIN public.ledger_entries le ON le.account_id = a.id
WHERE a.slug IN ('cash', 'bank') OR a.code IN ('1000', '1010')
  AND COALESCE(le.is_reversed, false) = false
  AND le.voucher_no NOT LIKE 'REV-%'
GROUP BY a.id, a.name, a.slug;


-- ------------------------------------------------------------------------------
-- CHECK 5: P&L NET PROFIT SUMMARY
-- ------------------------------------------------------------------------------
WITH sales_revenue AS (
  SELECT ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) AS revenue
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'sales' OR a.code LIKE '3%' OR a.account_type ILIKE 'income%')
    AND COALESCE(le.is_reversed, false) = false AND le.voucher_no NOT LIKE 'REV-%'
),
cogs_expense AS (
  SELECT ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) AS cogs
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%cost of goods%')
    AND COALESCE(le.is_reversed, false) = false AND le.voucher_no NOT LIKE 'REV-%'
),
expenses AS (
  SELECT ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) AS total_exp
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.account_type ILIKE 'expense%' OR a.code LIKE '5%')
    AND a.slug NOT IN ('cogs') AND a.code NOT IN ('4100') AND a.name NOT ILIKE '%cost of goods%'
    AND COALESCE(le.is_reversed, false) = false AND le.voucher_no NOT LIKE 'REV-%'
)
SELECT
  '5. PROFIT & LOSS HEALTH' AS health_check,
  sr.revenue AS sales_revenue_pkr,
  ce.cogs AS cogs_pkr,
  ROUND(sr.revenue - ce.cogs, 2) AS gross_profit_pkr,
  ex.total_exp AS operating_expenses_pkr,
  ROUND((sr.revenue - ce.cogs) - ex.total_exp, 2) AS net_profit_pkr
FROM sales_revenue sr
CROSS JOIN cogs_expense ce
CROSS JOIN expenses ex;

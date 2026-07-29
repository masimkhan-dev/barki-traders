-- ==============================================================================
-- BARKI TRADERS: LAST 30 DAYS & CURRENT MONTH PROFIT & LOSS AUDIT SCRIPT
-- Target Database: Supabase PostgreSQL
-- Purpose: Complete break-down of Sales Revenue, COGS, Gross Profit, Expenses,
--          and Net Profit for the Last 30 Days vs Current Calendar Month.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. PROFIT & LOSS SUMMARY: LAST 30 DAYS (Rolling 30 Days)
-- ------------------------------------------------------------------------------
WITH sales_revenue AS (
  SELECT ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) AS revenue
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'sales' OR a.code LIKE '3%' OR a.account_type ILIKE 'income%')
    AND le.posting_date >= (CURRENT_DATE - INTERVAL '30 days')
    AND COALESCE(le.is_reversed, false) = false AND le.voucher_no NOT LIKE 'REV-%'
),
cogs_expense AS (
  SELECT ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) AS cogs
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%cost of goods%')
    AND le.posting_date >= (CURRENT_DATE - INTERVAL '30 days')
    AND COALESCE(le.is_reversed, false) = false AND le.voucher_no NOT LIKE 'REV-%'
),
expenses AS (
  SELECT ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) AS total_exp
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.account_type ILIKE 'expense%' OR a.code LIKE '5%')
    AND a.slug NOT IN ('cogs') AND a.code NOT IN ('4100') AND a.name NOT ILIKE '%cost of goods%'
    AND le.posting_date >= (CURRENT_DATE - INTERVAL '30 days')
    AND COALESCE(le.is_reversed, false) = false AND le.voucher_no NOT LIKE 'REV-%'
)
SELECT
  '1. P&L SUMMARY (LAST 30 DAYS)' AS audit_period,
  sr.revenue AS sales_revenue_pkr,
  ce.cogs AS cogs_pkr,
  ROUND(sr.revenue - ce.cogs, 2) AS gross_profit_pkr,
  ex.total_exp AS operating_expenses_pkr,
  ROUND((sr.revenue - ce.cogs) - ex.total_exp, 2) AS net_profit_pkr
FROM sales_revenue sr
CROSS JOIN cogs_expense ce
CROSS JOIN expenses ex;


-- ------------------------------------------------------------------------------
-- 2. PROFIT & LOSS SUMMARY: CURRENT CALENDAR MONTH (1st of Month to Today)
-- ------------------------------------------------------------------------------
WITH sales_revenue AS (
  SELECT ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) AS revenue
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'sales' OR a.code LIKE '3%' OR a.account_type ILIKE 'income%')
    AND le.posting_date >= date_trunc('month', CURRENT_DATE)
    AND COALESCE(le.is_reversed, false) = false AND le.voucher_no NOT LIKE 'REV-%'
),
cogs_expense AS (
  SELECT ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) AS cogs
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%cost of goods%')
    AND le.posting_date >= date_trunc('month', CURRENT_DATE)
    AND COALESCE(le.is_reversed, false) = false AND le.voucher_no NOT LIKE 'REV-%'
),
expenses AS (
  SELECT ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) AS total_exp
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.account_type ILIKE 'expense%' OR a.code LIKE '5%')
    AND a.slug NOT IN ('cogs') AND a.code NOT IN ('4100') AND a.name NOT ILIKE '%cost of goods%'
    AND le.posting_date >= date_trunc('month', CURRENT_DATE)
    AND COALESCE(le.is_reversed, false) = false AND le.voucher_no NOT LIKE 'REV-%'
)
SELECT
  '2. P&L SUMMARY (CURRENT MONTH - 1ST TO TODAY)' AS audit_period,
  sr.revenue AS sales_revenue_pkr,
  ce.cogs AS cogs_pkr,
  ROUND(sr.revenue - ce.cogs, 2) AS gross_profit_pkr,
  ex.total_exp AS operating_expenses_pkr,
  ROUND((sr.revenue - ce.cogs) - ex.total_exp, 2) AS net_profit_pkr
FROM sales_revenue sr
CROSS JOIN cogs_expense ce
CROSS JOIN expenses ex;


-- ------------------------------------------------------------------------------
-- 3. PRODUCT-WISE SALES REVENUE VS SOLD LITERS (LAST 30 DAYS)
-- ------------------------------------------------------------------------------
SELECT
  ft.name AS fuel_product,
  COUNT(s.id) AS total_sale_vouchers,
  SUM(s.quantity) AS total_liters_sold,
  ROUND(AVG(s.rate_per_unit), 2) AS avg_selling_rate,
  ROUND(SUM(s.total_amount), 2) AS total_sales_revenue_pkr
FROM public.sales s
JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
WHERE s.sale_date >= (CURRENT_DATE - INTERVAL '30 days')
  AND COALESCE(s.is_reversed, false) = false
  AND s.voucher_no NOT LIKE 'REV-%'
GROUP BY ft.id, ft.name
ORDER BY total_sales_revenue_pkr DESC;


-- ------------------------------------------------------------------------------
-- 4. EXPENSE BREAKDOWN BY ACCOUNT (LAST 30 DAYS)
-- ------------------------------------------------------------------------------
SELECT
  a.code AS account_code,
  a.name AS expense_account,
  ROUND(SUM(le.debit_amount - le.credit_amount), 2) AS total_expense_pkr
FROM public.ledger_entries le
JOIN public.accounts a ON a.id = le.account_id
WHERE (a.account_type ILIKE 'expense%' OR a.code LIKE '5%')
  AND a.slug NOT IN ('cogs') AND a.code NOT IN ('4100') AND a.name NOT ILIKE '%cost of goods%'
  AND le.posting_date >= (CURRENT_DATE - INTERVAL '30 days')
  AND COALESCE(le.is_reversed, false) = false AND le.voucher_no NOT LIKE 'REV-%'
GROUP BY a.id, a.code, a.name
ORDER BY total_expense_pkr DESC;

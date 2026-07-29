-- ==============================================================================
-- BARKI TRADERS: WEEKLY PROFIT & LOSS AUDIT SCRIPT (CORRECTED COA CODES)
-- Target Database: Supabase PostgreSQL
-- Run Location: Supabase SQL Editor
-- Chart of Accounts Mapping in FDMS:
--   1xxx = Assets
--   2xxx = Liabilities
--   3xxx = Equity / Owner's Capital
--   4xxx = Revenue / Sales (Account 4000 = Sales Revenue)
--   4100 = Cost of Goods Sold (COGS)
--   5xxx = Expenses
-- ==============================================================================

WITH RECURSIVE weeks AS (
  SELECT 
    '2026-06-01'::DATE AS week_start,
    '2026-06-07'::DATE AS week_end,
    1 AS week_num
  UNION ALL
  SELECT 
    (week_start + INTERVAL '7 days')::DATE,
    LEAST((week_end + INTERVAL '7 days')::DATE, CURRENT_DATE),
    week_num + 1
  FROM weeks
  WHERE week_start + INTERVAL '7 days' <= CURRENT_DATE
),
weekly_sales AS (
  SELECT 
    w.week_num,
    w.week_start,
    w.week_end,
    COALESCE(SUM(s.quantity), 0) AS total_liters_sold
  FROM weeks w
  LEFT JOIN public.sales s 
    ON s.sale_date BETWEEN w.week_start AND w.week_end
   AND COALESCE(s.is_reversed, false) = false
   AND s.voucher_no NOT LIKE 'REV-%'
  GROUP BY w.week_num, w.week_start, w.week_end
),
weekly_financials AS (
  SELECT 
    w.week_num,
    w.week_start,
    w.week_end,
    -- Total Revenue from Ledger (Income / Account Code 4xxx / Sales)
    ROUND(COALESCE(SUM(
      CASE WHEN a.account_type = 'income' OR a.slug = 'sales' OR a.code LIKE '40%' 
           THEN le.credit_amount - le.debit_amount 
           ELSE 0 END
    ), 0), 2) AS revenue,
    
    -- Total COGS from Ledger (Debit - Credit on COGS Account 4100 / 'cogs')
    ROUND(COALESCE(SUM(
      CASE WHEN a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%cost of goods%' 
           THEN le.debit_amount - le.credit_amount 
           ELSE 0 END
    ), 0), 2) AS cogs,
    
    -- Total Operating Expenses from Ledger (Expense Accounts / Code 5xxx excluding COGS)
    ROUND(COALESCE(SUM(
      CASE WHEN (a.account_type ILIKE 'expense%' OR a.code LIKE '5%')
            AND a.slug NOT IN ('cogs') AND a.code NOT IN ('4100') AND a.name NOT ILIKE '%cost of goods%'
           THEN le.debit_amount - le.credit_amount 
           ELSE 0 END
    ), 0), 2) AS expenses
  FROM weeks w
  LEFT JOIN public.ledger_entries le 
    ON le.posting_date BETWEEN w.week_start AND w.week_end
   AND COALESCE(le.is_reversed, false) = false
   AND le.voucher_no NOT LIKE 'REV-%'
  LEFT JOIN public.accounts a ON a.id = le.account_id
  GROUP BY w.week_num, w.week_start, w.week_end
)
SELECT 
  f.week_num AS week_number,
  f.week_start || ' to ' || f.week_end AS period,
  s.total_liters_sold,
  f.revenue AS sales_revenue_pkr,
  f.cogs AS cogs_pkr,
  ROUND(f.revenue - f.cogs, 2) AS gross_profit_pkr,
  f.expenses AS operating_expenses_pkr,
  ROUND((f.revenue - f.cogs) - f.expenses, 2) AS net_profit_pkr
FROM weekly_financials f
JOIN weekly_sales s ON s.week_num = f.week_num
ORDER BY f.week_num ASC;

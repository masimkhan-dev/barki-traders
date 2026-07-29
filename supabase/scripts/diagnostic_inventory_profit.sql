-- ==============================================================================
-- DIAGNOSTIC AUDIT SCRIPT: ACTUAL INVENTORY & ACTUAL PROFIT
-- Target Database: Supabase PostgreSQL (Fuel Management & Double-Entry Ledger)
-- Run Location: Supabase SQL Editor
-- Description: Audits inventory balances, WAC valuation, GL control drift,
--              Revenue, COGS, Expenses, and Net Profit.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- SECTION 1: INVENTORY DIAGNOSIS (Physical vs Cached vs GL Ledger Value)
-- ------------------------------------------------------------------------------

WITH physical_movement AS (
  SELECT
    fuel_type_id,
    SUM(qty) AS computed_qty,
    SUM(purchased_qty) AS total_purchased_qty,
    SUM(sold_qty) AS total_sold_qty
  FROM (
    SELECT 
      fuel_type_id, 
      quantity AS qty, 
      quantity AS purchased_qty, 
      0 AS sold_qty
    FROM public.purchases
    WHERE COALESCE(is_reversed, false) = false
      AND voucher_no NOT LIKE 'REV-%'

    UNION ALL

    SELECT 
      fuel_type_id, 
      -quantity AS qty, 
      0 AS purchased_qty, 
      quantity AS sold_qty
    FROM public.sales
    WHERE COALESCE(is_reversed, false) = false
      AND voucher_no NOT LIKE 'REV-%'
  ) tx
  GROUP BY fuel_type_id
),
inventory_summary AS (
  SELECT
    ft.id AS fuel_type_id,
    ft.name AS fuel_name,
    COALESCE(i.quantity, 0) AS cached_qty,
    COALESCE(i.avg_cost, 0) AS cached_avg_cost,
    ROUND(COALESCE(i.quantity, 0) * COALESCE(i.avg_cost, 0), 2) AS cached_stock_value,
    COALESCE(pm.computed_qty, 0) AS computed_qty,
    COALESCE(pm.total_purchased_qty, 0) AS total_purchased_qty,
    COALESCE(pm.total_sold_qty, 0) AS total_sold_qty,
    ROUND(COALESCE(pm.computed_qty, 0) * COALESCE(i.avg_cost, 0), 2) AS computed_stock_value,
    ROUND(COALESCE(i.quantity, 0) - COALESCE(pm.computed_qty, 0), 2) AS qty_drift
  FROM public.fuel_types ft
  LEFT JOIN public.inventory i ON i.fuel_type_id = ft.id
  LEFT JOIN physical_movement pm ON pm.fuel_type_id = ft.id
)
SELECT 
  '--- 1. INVENTORY BREAKDOWN BY FUEL TYPE ---' AS audit_section,
  fuel_name,
  cached_qty,
  cached_avg_cost,
  cached_stock_value,
  computed_qty,
  qty_drift,
  total_purchased_qty,
  total_sold_qty
FROM inventory_summary
ORDER BY fuel_name;


-- ------------------------------------------------------------------------------
-- SECTION 2: INVENTORY GL CONTROL ACCOUNT VS PHYSICAL VALUATION DRIFT
-- ------------------------------------------------------------------------------

WITH stock_valuation AS (
  SELECT 
    ROUND(COALESCE(SUM(quantity * avg_cost), 0), 2) AS total_inventory_valuation
  FROM public.inventory
),
ledger_inventory AS (
  SELECT 
    ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) AS gl_inventory_balance
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'inventory' OR a.code = '1200')
    AND COALESCE(le.is_reversed, false) = false
    AND le.voucher_no NOT LIKE 'REV-%'
)
SELECT
  '--- 2. INVENTORY GL DRIFT CHECK ---' AS audit_section,
  sv.total_inventory_valuation AS inventory_table_value,
  li.gl_inventory_balance AS ledger_1200_inventory_value,
  ROUND(sv.total_inventory_valuation - li.gl_inventory_balance, 2) AS inventory_gl_discrepancy
FROM stock_valuation sv
CROSS JOIN ledger_inventory li;


-- ------------------------------------------------------------------------------
-- SECTION 3: PROFIT & LOSS DIAGNOSIS (Sales, COGS, Gross Profit, Expenses, Net Profit)
-- ------------------------------------------------------------------------------

WITH sales_revenue AS (
  -- Total Sales Revenue from Ledger (Credit - Debit on Sales Account)
  SELECT 
    ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) AS total_revenue
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'sales' OR a.code LIKE '3%' OR a.type ILIKE 'revenue%')
    AND COALESCE(le.is_reversed, false) = false
    AND le.voucher_no NOT LIKE 'REV-%'
),
cogs_expense AS (
  -- Total COGS from Ledger (Debit - Credit on COGS Account)
  SELECT 
    ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) AS total_cogs
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%cost of goods%')
    AND COALESCE(le.is_reversed, false) = false
    AND le.voucher_no NOT LIKE 'REV-%'
),
other_expenses AS (
  -- Total Operating / Other Expenses (Debit - Credit)
  SELECT 
    ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) AS total_operating_expenses
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.type ILIKE 'expense%' OR a.code LIKE '5%' OR a.category ILIKE 'expense%')
    AND a.slug NOT IN ('cogs')
    AND a.code NOT IN ('4100')
    AND a.name NOT ILIKE '%cost of goods%'
    AND COALESCE(le.is_reversed, false) = false
    AND le.voucher_no NOT LIKE 'REV-%'
)
SELECT
  '--- 3. FINANCIAL PROFIT & LOSS AUDIT ---' AS audit_section,
  sr.total_revenue,
  ce.total_cogs,
  ROUND(sr.total_revenue - ce.total_cogs, 2) AS gross_profit,
  oe.total_operating_expenses,
  ROUND((sr.total_revenue - ce.total_cogs) - oe.total_operating_expenses, 2) AS net_profit
FROM sales_revenue sr
CROSS JOIN cogs_expense ce
CROSS JOIN other_expenses oe;


-- ------------------------------------------------------------------------------
-- SECTION 4: DOUBLE-ENTRY LEDGER BALANCE & INTEGRITY VERIFICATION
-- ------------------------------------------------------------------------------

SELECT
  '--- 4. TRIAL BALANCE OVERALL SANE CHECK ---' AS audit_section,
  ROUND(SUM(le.debit_amount), 2) AS total_debit,
  ROUND(SUM(le.credit_amount), 2) AS total_credit,
  ROUND(SUM(le.debit_amount) - SUM(le.credit_amount), 2) AS ledger_imbalance
FROM public.ledger_entries le
WHERE COALESCE(le.is_reversed, false) = false
  AND le.voucher_no NOT LIKE 'REV-%';

-- ------------------------------------------------------------------------------
-- SECTION 5: UNBALANCED VOUCHERS (IF ANY EXIST)
-- ------------------------------------------------------------------------------

SELECT 
  le.voucher_no,
  ROUND(SUM(le.debit_amount), 2) AS debit,
  ROUND(SUM(le.credit_amount), 2) AS credit,
  ROUND(SUM(le.debit_amount) - SUM(le.credit_amount), 2) AS diff
FROM public.ledger_entries le
WHERE COALESCE(le.is_reversed, false) = false
  AND le.voucher_no NOT LIKE 'REV-%'
GROUP BY le.voucher_no
HAVING ABS(SUM(le.debit_amount) - SUM(le.credit_amount)) > 0.01
ORDER BY le.voucher_no;

-- =================================================================
-- FIX P&L ROOT CAUSE: PREVENT DOUBLE EXPENSING
-- Purpose: 
-- 1. Ensure ONLY 'expense' type accounts appear in P&L.
-- 2. Explicitly EXCLUDE 'asset' accounts (like Fuel Purchase Cost / Inventory) from P&L.
-- 3. Maintain strict separation between Direct Costs and Operating Expenses.
-- =================================================================

BEGIN;

-- 1. CLEANUP OLD LOGIC
DROP FUNCTION IF EXISTS public.get_profit_loss(DATE, DATE) CASCADE;

-- 2. CREATE ROBUST P&L RPC
CREATE OR REPLACE FUNCTION public.get_profit_loss(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    section TEXT,
    account_name TEXT,
    amount NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    -- A. INCOME (Sales Revenue ONLY)
    SELECT 'Income'::TEXT, a.name, COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'income' AND a.is_active = true
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- B. DIRECT COSTS (Cost of Goods Sold ONLY)
    -- We ONLY pull from accounts that are explicitly 'expense' type.
    -- We ignore 'Fuel Purchase Cost' if it is an Asset.
    SELECT 'Direct Costs'::TEXT, a.name, COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense' 
      AND (a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%Cost of Goods Sold%')
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- C. OPERATING EXPENSES (Excluding the COGS defined above)
    SELECT 'Expenses'::TEXT, a.name, COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense' AND a.is_active = true
      AND (a.slug IS NULL OR a.slug <> 'cogs')
      AND a.code <> '4100'
      AND a.name NOT ILIKE '%Cost of Goods Sold%'
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0;
END;
$$;

COMMIT;

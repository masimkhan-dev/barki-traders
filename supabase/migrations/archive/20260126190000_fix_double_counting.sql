-- =================================================================
-- FIX DOUBLE COUNTING IN P&L REPORT
-- Purpose: Exclude COGS from Operating Expenses section to prevent
-- calculating it twice (once as Direct Cost, again as Expense)
-- =================================================================

BEGIN;

-- Drop existing functions to allow clean definition
DROP FUNCTION IF EXISTS public.get_profit_loss(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_balance_sheet(DATE) CASCADE;

-- =================================================================
-- REVISED P&L FUNCTION (Fixes Double Counting)
-- =================================================================

CREATE FUNCTION public.get_profit_loss(
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
    -- 1. INCOME (Revenue)
    SELECT 
        'Income'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
        AND le.posting_date <= p_end_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.account_type = 'income' AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- 2. DIRECT COSTS (COGS Only)
    -- We specifically classify COGS account here as Direct Cost
    SELECT 
        'Direct Costs'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
        AND le.posting_date <= p_end_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE (a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%Cost of Goods%') 
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    UNION ALL
    
    -- 3. OPERATING EXPENSES (Excluding COGS)
    SELECT 
        'Expenses'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
        AND le.posting_date <= p_end_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.account_type = 'expense' 
      AND a.is_active = true
      AND a.slug != 'cogs' AND a.code != '4100' AND a.name NOT ILIKE '%Cost of Goods%' -- EXCLUDE COGS HERE
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    ORDER BY section DESC, account_name;
END;
$$;

-- =================================================================
-- REVISED BALANCE SHEET FUNCTION (Matching P&L Logic)
-- =================================================================

CREATE FUNCTION public.get_balance_sheet(
    p_as_of_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    section TEXT,
    account_name TEXT,
    amount NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total_revenue NUMERIC;
    v_total_expense NUMERIC;
    v_net_profit NUMERIC;
BEGIN
    -- Calculate Revenue (Credit Balance)
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_total_revenue
    FROM public.ledger_entries le
    JOIN public.accounts a ON a.id = le.account_id
    WHERE le.posting_date <= p_as_of_date
      AND COALESCE(le.is_reversed, false) = false
      AND a.account_type = 'income';

    -- Calculate All Expenses including COGS (Debit Balance)
    SELECT COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    INTO v_total_expense
    FROM public.ledger_entries le
    JOIN public.accounts a ON a.id = le.account_id
    WHERE le.posting_date <= p_as_of_date
      AND COALESCE(le.is_reversed, false) = false
      AND a.account_type = 'expense';

    v_net_profit := v_total_revenue - v_total_expense;

    -- Return Assets (Dr)
    RETURN QUERY
    SELECT 
        'Assets'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.account_type = 'asset' AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    UNION ALL
    
    -- Return Liabilities (Cr)
    SELECT 
        'Liabilities'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.account_type = 'liability' AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- Return Equity (Cr)
    SELECT 
        'Equity'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.account_type = 'equity' AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- Add Retained Earnings (Net Profit)
    SELECT 
        'Equity'::TEXT,
        'Net Profit (Current)'::TEXT,
        v_net_profit
    WHERE v_net_profit <> 0
    
    ORDER BY section DESC, account_name;
END;
$$;

COMMIT;

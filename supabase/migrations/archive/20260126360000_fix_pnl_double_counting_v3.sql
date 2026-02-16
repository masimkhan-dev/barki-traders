-- =================================================================
-- FIX P&L DOUBLE COUNTING (VERSION 3 - STRICT TYPE FILTER)
-- Purpose: 
-- 1. Ensure ONLY 'expense' types are included in Cost/Expense sections.
-- 2. Prevent 'asset' (Inventory) accounts named after costs from leaking into P&L.
-- 3. Perfectly align P&L Net Profit with Balance Sheet.
-- =================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_profit_loss(DATE, DATE) CASCADE;

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
    -- IDENTIFY COGS BY SLUG/NAME BUT ONLY WITHIN EXPENSE TYPE
    -- This prevents the "Inventory Asset" from being counted as a "Direct Cost"
    WITH cogs_accounts AS (
        SELECT id FROM public.accounts 
        WHERE account_type = 'expense'
          AND (
               slug = 'cogs' 
               OR code = '4100' 
               OR name ILIKE '%Cost of Goods%' 
               OR name ILIKE '%COGS%' 
               OR name ILIKE '%Purchase Cost%'
          )
    )
    -- 1. INCOME (Sales Revenue)
    SELECT 
        'Income'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'income' AND a.is_active = true
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- 2. DIRECT COSTS (Strictly COGS Accounts of type EXPENSE)
    -- This section defines the "Gross Profit" layer
    SELECT 
        'Direct Costs'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.id IN (SELECT id FROM cogs_accounts) -- Must be EXPENSE + COGS
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- 3. OPERATING EXPENSES (Strictly NON-COGS Accounts of type EXPENSE)
    -- Any account identified as COGS above is mathematically EXCLUDED here
    SELECT 
        'Expenses'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense'
      AND a.id NOT IN (SELECT id FROM cogs_accounts) -- EXCLUDE ALL COGS
      AND a.is_active = true
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0;
END;
$$;

COMMIT;

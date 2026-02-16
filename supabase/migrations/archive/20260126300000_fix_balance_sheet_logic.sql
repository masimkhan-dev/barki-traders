-- =================================================================
-- FIX BALANCE SHEET LOGIC (INCLUDE PARTIES)
-- Purpose: Correctly calculate Assets and Liabilities by including
--          Party balances (Customers as Assets, Suppliers as Liabilities)
--          which were previously missed by the Accounts-only join.
-- =================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_balance_sheet(DATE) CASCADE;

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
    v_net_profit NUMERIC;
BEGIN
    -- 1. CALCULATE NET PROFIT (Revenue - Expenses)
    -- Must include ALL ledger entries irrespective of party link
    SELECT COALESCE(SUM(
        CASE 
            WHEN a.account_type = 'income' THEN le.credit_amount - le.debit_amount
            WHEN a.account_type = 'expense' THEN le.debit_amount - le.credit_amount
            ELSE 0
        END
    ), 0)
    INTO v_net_profit
    FROM public.ledger_entries le
    JOIN public.accounts a ON a.id = le.account_id
    WHERE le.posting_date <= p_as_of_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND a.account_type IN ('income', 'expense');

    RETURN QUERY
    -- 2. ASSETS
    -- A) System Assets (Cash, Bank, Inventory, Fixed Assets)
    SELECT 
        'Assets'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'asset' 
      AND a.slug NOT IN ('ar', 'ap') -- Exclude Control Accounts (we add parties below)
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0

    UNION ALL

    -- B) Customer Balances (Accounts Receivable)
    SELECT 
        'Assets'::TEXT,
        'Accounts Receivable (Customers)',
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE p.type IN ('customer', 'both')
      AND le.posting_date <= p_as_of_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    UNION ALL
    
    -- 3. LIABILITIES
    -- A) System Liabilities (Loans, Taxes)
    SELECT 
        'Liabilities'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'liability'
      AND a.slug NOT IN ('ap') -- Exclude AP Control (we add suppliers below)
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0

    UNION ALL

    -- B) Supplier Balances (Accounts Payable)
    SELECT 
        'Liabilities'::TEXT,
        'Accounts Payable (Suppliers)',
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE p.type IN ('supplier', 'both')
      AND le.posting_date <= p_as_of_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- 4. EQUITY
    SELECT 
        'Equity'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'equity' AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- Net Profit
    SELECT 
        'Equity'::TEXT,
        'Net Profit (Current Period)',
        v_net_profit
    WHERE v_net_profit <> 0
    
    ORDER BY section DESC, account_name;
END;
$$;

COMMIT;

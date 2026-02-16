-- =================================================================
-- REPAIR BALANCE SHEET: AGGREGATE SYSTEM ACCOUNTS + PARTIES
-- Purpose: 
-- 1. Correctly include Parties (Market Balance) in Assets/Liabilities
-- 2. Prevent the 245k mismatch by ensuring every ledger entry 
--    is counted exactly once.
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
    -- 1. CALCULATE NET PROFIT (Income - Expenses)
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
    -- A) System Assets (Cash, Bank, Inventory, etc.) - Excluding AR Account (slug='ar')
    SELECT 
        'Assets'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'asset' 
      AND a.slug != 'ar' -- We add the detailed Customers below
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0

    UNION ALL

    -- B) Market Receivables (Customers with Debit balance)
    SELECT 
        'Assets'::TEXT,
        'Accounts Receivable (Customers)',
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.ledger_entries le
    JOIN public.accounts a ON a.id = le.account_id
    WHERE a.slug = 'ar' 
      AND le.posting_date <= p_as_of_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    UNION ALL
    
    -- 3. LIABILITIES
    -- A) System Liabilities (excluding AP)
    SELECT 
        'Liabilities'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'liability'
      AND a.slug != 'ap'
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0

    UNION ALL

    -- B) Market Payables (Suppliers with Credit balance)
    SELECT 
        'Liabilities'::TEXT,
        'Accounts Payable (Suppliers)',
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.ledger_entries le
    JOIN public.accounts a ON a.id = le.account_id
    WHERE a.slug = 'ap'
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
    
    -- Add Net Profit
    SELECT 
        'Equity'::TEXT,
        'Net Profit (Current Period)',
        v_net_profit
    WHERE v_net_profit <> 0
    
    ORDER BY section DESC, account_name;
END;
$$;

COMMIT;

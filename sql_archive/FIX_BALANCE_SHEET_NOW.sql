-- =================================================================
-- EMERGENCY FIX: Balance Sheet 400 Error
-- Uses the PROVEN working structure from RESTORE_BALANCE_SHEET_WORKING.sql
-- =================================================================

BEGIN;

-- Drop old function
DROP FUNCTION IF EXISTS public.get_financial_position(DATE) CASCADE;

-- Recreate with working structure
CREATE OR REPLACE FUNCTION public.get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE
    v_net_profit NUMERIC;
BEGIN
    -- 1. Calculate Net Profit from Income/Expense accounts
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_net_profit
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    RETURN QUERY
    -- 2. SYSTEM ASSETS (Cash, Bank, Inventory)
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND (a.slug IS NULL OR a.slug NOT IN ('ar', 'ap'))
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL

    -- 3. PARTY ASSETS (Receivables)
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT,
           (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
    FROM public.parties p
    LEFT JOIN public.ledger_entries le ON le.party_id = p.id 
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.id, p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) > 0

    UNION ALL

    -- 4. LIABILITIES (System Accounts)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND (a.slug IS NULL OR a.slug NOT IN ('ar', 'ap'))
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 5. PARTY LIABILITIES (Payables)
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT,
           ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
    FROM public.parties p
    LEFT JOIN public.ledger_entries le ON le.party_id = p.id 
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.id, p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) < 0

    UNION ALL

    -- 6. EQUITY
    SELECT 'EQUITY'::TEXT, 'Owner Capital'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE (a.account_type = 'equity' OR a.code = '3000') 
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 7. Net Profit
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Net Profit'::TEXT, v_net_profit;
END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;

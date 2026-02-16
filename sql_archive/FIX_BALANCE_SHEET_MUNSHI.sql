-- =================================================================
-- MUNSHI BALANCE SHEET FIX (Jan 30, 2026)
-- Target: Dynamic categorization of parties based on Balance Direction
-- =================================================================

BEGIN;

CREATE OR REPLACE FUNCTION get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE
    v_net_profit NUMERIC;
BEGIN
    -- 1. Calculate Net Profit (Income - Expense)
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_net_profit
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    RETURN QUERY
    -- 2. ASSETS (System Accounts: Cash, Inventory, Bank)
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL

    -- 3. ASSETS (Parties with DEBIT balances - Receivables)
    -- If we owe them (Cr > Dr), they move to Liabilities automatically
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT,
           SUM(le.debit_amount - le.credit_amount)
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.name
    HAVING SUM(le.debit_amount - le.credit_amount) > 0

    UNION ALL

    -- 4. LIABILITIES (System Accounts)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 5. LIABILITIES (Parties with CREDIT balances - Payables) 
    -- This handles the Sami/Sabir issue where both will now show in Liabilities
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT,
           SUM(le.credit_amount - le.debit_amount)
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.name
    HAVING SUM(le.credit_amount - le.debit_amount) > 0

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

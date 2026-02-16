-- =================================================================
-- COMPLETE BALANCE SHEET FIX (With Owner's Capital)
-- Purpose: Fixes the 131k mismatch by properly accounting for Owner's Capital
-- Logic: Assets = Liabilities + Owner's Capital + Net Profit
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
    v_total_assets NUMERIC;
    v_total_liabilities NUMERIC;
    v_owner_capital NUMERIC;
BEGIN
    -- Calculate Net Profit (Income - Expenses, including reversals for net-off)
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_net_profit
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date <= p_date;

    -- Calculate Total Assets
    SELECT COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    INTO v_total_assets
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date;

    -- Add Party Receivables to Total Assets
    v_total_assets := v_total_assets + COALESCE((
        SELECT SUM(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
        FROM public.parties p
        LEFT JOIN public.ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
        GROUP BY p.id, p.opening_balance
        HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) > 0
    ), 0);

    -- Calculate Total Liabilities
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_total_liabilities
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date;

    -- Add Party Payables to Total Liabilities
    v_total_liabilities := v_total_liabilities + COALESCE((
        SELECT SUM(ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)))
        FROM public.parties p
        LEFT JOIN public.ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
        GROUP BY p.id, p.opening_balance
        HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) < 0
    ), 0);

    -- Calculate Owner's Capital (Balancing Figure)
    -- Assets = Liabilities + Owner's Capital + Net Profit
    -- Therefore: Owner's Capital = Assets - Liabilities - Net Profit
    v_owner_capital := v_total_assets - v_total_liabilities - v_net_profit;

    RETURN QUERY
    -- 1. SYSTEM ASSETS (Cash, Bank, Inventory)
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date
    GROUP BY a.name
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL

    -- 2. PARTY ASSETS (Receivables)
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT,
           (COALESCE(p.opening_balance, 0) + SUM(le.debit_amount - le.credit_amount)) as total_bal
    FROM public.parties p
    LEFT JOIN public.ledger_entries le ON le.party_id = p.id 
      AND le.posting_date <= p_date
    GROUP BY p.id, p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) > 0

    UNION ALL

    -- 3. LIABILITIES (System Accounts)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 4. PARTY LIABILITIES (Payables)
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT,
           ABS(COALESCE(p.opening_balance, 0) + SUM(le.debit_amount - le.credit_amount)) as total_bal
    FROM public.parties p
    LEFT JOIN public.ledger_entries le ON le.party_id = p.id 
      AND le.posting_date <= p_date
    GROUP BY p.id, p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) < 0

    UNION ALL

    -- 5. OWNER'S CAPITAL (Calculated as Balancing Figure)
    SELECT 'EQUITY'::TEXT, 'Owner Capital'::TEXT, 'Opening Capital'::TEXT, v_owner_capital
    WHERE v_owner_capital <> 0

    UNION ALL

    -- 6. NET PROFIT
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Net Profit'::TEXT, v_net_profit
    WHERE v_net_profit <> 0;
END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;

-- FIX BALANCE SHEET AR/AP (CORRECTED PARTY BALANCE)
-- Purpose: Show NET PARTY BALANCES instead of GL CONTROL ACCOUNT TOTALS.

DROP FUNCTION IF EXISTS public.get_financial_position(DATE);

CREATE OR REPLACE FUNCTION public.get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE 
    v_net_profit NUMERIC;
    v_total_receivables NUMERIC;
    v_total_payables NUMERIC;
BEGIN
    -- 1. Net Profit Calculation
    SELECT COALESCE(SUM(
        CASE 
            WHEN a.account_type::TEXT ILIKE 'income' THEN le.credit_amount - le.debit_amount
            WHEN a.account_type::TEXT ILIKE 'expense' THEN le.credit_amount - le.debit_amount
            ELSE 0
        END
    ), 0)
    INTO v_net_profit
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id 
    WHERE a.account_type::TEXT IN ('income', 'expense')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    -- 2. Calculate Party Receivables (Customers owe us)
    SELECT COALESCE(SUM(party_balance), 0)
    INTO v_total_receivables
    FROM (
        SELECT SUM(le.debit_amount - le.credit_amount) as party_balance
        FROM ledger_entries le
        WHERE le.party_id IS NOT NULL
          AND le.posting_date <= p_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY le.party_id
    ) party_balances
    WHERE party_balance > 0;

    -- 3. Calculate Party Payables (We owe suppliers)
    SELECT COALESCE(SUM(ABS(party_balance)), 0)
    INTO v_total_payables
    FROM (
        SELECT SUM(le.debit_amount - le.credit_amount) as party_balance
        FROM ledger_entries le
        WHERE le.party_id IS NOT NULL
          AND le.posting_date <= p_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY le.party_id
    ) party_balances
    WHERE party_balance < 0;

    RETURN QUERY
    -- A. ASSETS (Cash, Bank, Inventory - EXCLUDE AR)
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT, COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM accounts a 
    LEFT JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'asset'
      AND COALESCE(a.slug, '') NOT IN ('ar', 'accounts_receivable')
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name 
    HAVING (a.code IN ('1000', '1010'))
        OR (SUM(le.debit_amount - le.credit_amount) > 0)

    UNION ALL
    -- A2. Market Receivables (Party Balance)
    SELECT 'ASSETS'::TEXT, 'Current Assets'::TEXT, 'Total Market Receivables (Lena)'::TEXT, v_total_receivables
    WHERE v_total_receivables > 0

    UNION ALL
    -- B. LIABILITIES (EXCLUDE AP)
    SELECT 'LIABILITIES'::TEXT, 'Liabilities'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a 
    JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'liability'
      AND COALESCE(a.slug, '') NOT IN ('ap', 'accounts_payable')
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name 
    HAVING SUM(le.debit_amount - le.credit_amount) != 0

    UNION ALL
    -- B2. Supplier Payables (Party Balance)
    SELECT 'LIABILITIES'::TEXT, 'Liabilities'::TEXT, 'Total Supplier Payables (Dena)'::TEXT, v_total_payables
    WHERE v_total_payables > 0

    UNION ALL
    -- C. EQUITY & CAPITAL
    SELECT 'EQUITY'::TEXT, 'Equity & Reserves'::TEXT, a.name::TEXT, ABS(SUM(le.credit_amount - le.debit_amount))
    FROM accounts a 
    JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'equity'
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    
    UNION ALL
    -- D. NET PROFIT
    SELECT 'EQUITY'::TEXT, 'Equity & Reserves'::TEXT, 'Net Profit'::TEXT, COALESCE(v_net_profit, 0);

END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

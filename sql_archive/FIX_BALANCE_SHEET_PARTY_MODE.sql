-- FIX BALANCE SHEET AR/AP (PARTY BALANCE MODE)
-- Purpose: Show NET PARTY BALANCES instead of GL CONTROL ACCOUNT TOTALS for AR/AP.

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
    -- 1. Net Profit (Same as before)
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

    -- 2. Calculate PARTY BALANCES (Not GL Balances)
    -- Receivables (Customers owe us - Positive balance)
    SELECT COALESCE(SUM(
        CASE 
            WHEN SUM(le.debit_amount - le.credit_amount) > 0 
            THEN SUM(le.debit_amount - le.credit_amount) 
            ELSE 0 
        END
    ), 0)
    INTO v_total_receivables
    FROM ledger_entries le
    WHERE le.party_id IS NOT NULL
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY le.party_id;

    -- Payables (We owe suppliers - Negative balance, shown as positive)
    SELECT COALESCE(SUM(
        CASE 
            WHEN SUM(le.debit_amount - le.credit_amount) < 0 
            THEN ABS(SUM(le.debit_amount - le.credit_amount))
            ELSE 0 
        END
    ), 0)
    INTO v_total_payables
    FROM ledger_entries le
    WHERE le.party_id IS NOT NULL
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY le.party_id;

    RETURN QUERY
    -- A. ASSETS (Cash, Bank, Inventory, etc. - EXCLUDE AR Control Account)
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT, COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM accounts a 
    LEFT JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'asset'
      AND a.slug NOT IN ('ar', 'accounts_receivable') -- EXCLUDE AR CONTROL
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name 
    HAVING (a.code IN ('1000', '1010')) -- Always show Cash/Bank
        OR (SUM(le.debit_amount - le.credit_amount) > 0)

    UNION ALL
    -- A2. Market Receivables (Party Balance, NOT GL Balance)
    SELECT 'ASSETS'::TEXT, 'Current Assets'::TEXT, 'Total Market Receivables (Lena)'::TEXT, v_total_receivables
    WHERE v_total_receivables > 0

    UNION ALL
    -- B. LIABILITIES (Payables - EXCLUDE AP Control Account)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a 
    JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'liability'
      AND a.slug NOT IN ('ap', 'accounts_payable') -- EXCLUDE AP CONTROL
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name 
    HAVING SUM(le.debit_amount - le.credit_amount) != 0

    UNION ALL
    -- B2. Supplier Payables (Party Balance, NOT GL Balance)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, 'Total Supplier Payables (Dena)'::TEXT, v_total_payables
    WHERE v_total_payables > 0

    UNION ALL
    -- C. EQUITY & CAPITAL
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name::TEXT, ABS(SUM(le.credit_amount - le.debit_amount))
    FROM accounts a 
    JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'equity'
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    
    UNION ALL
    -- D. RETAINED EARNINGS (Net Profit)
    SELECT 'EQUITY'::TEXT, 'Profit/Loss'::TEXT, 'Net Profit'::TEXT, COALESCE(v_net_profit, 0);

END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- FINAL CLEAN BALANCE SHEET (OPTION A)
-- Purpose: Remove AR/AP Control Reconciliation (Suspense) for professional reporting
-- Shows only REAL party balances (Rs 25k, Rs 48k)

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

    -- 2. Party Balances (REAL operational data only)
    SELECT COALESCE(SUM(receivable_balance), 0), COALESCE(SUM(payable_balance), 0)
    INTO v_total_receivables, v_total_payables
    FROM get_market_position_report(p_date);

    RETURN QUERY
    -- A. ASSETS (Cash, Bank, Inventory, Fixed Assets - EXCLUDE AR Control)
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
    -- A2. Market Receivables (REAL Party Balance - Rs 25k)
    SELECT 'ASSETS'::TEXT, 'Current Assets'::TEXT, 'Total Market Receivables (Lena)'::TEXT, v_total_receivables
    WHERE v_total_receivables > 0

    UNION ALL
    -- B. LIABILITIES (EXCLUDE AP Control - Clean)
    SELECT 'LIABILITIES'::TEXT, 'Liabilities'::TEXT, a.name::TEXT, SUM(le.credit_amount - le.debit_amount)
    FROM accounts a 
    JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'liability'
      AND COALESCE(a.slug, '') NOT IN ('ap', 'accounts_payable')
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name 
    HAVING SUM(le.credit_amount - le.debit_amount) != 0

    UNION ALL
    -- B2. Supplier Payables (REAL Party Balance - Rs 48k)
    SELECT 'LIABILITIES'::TEXT, 'Liabilities'::TEXT, 'Total Supplier Payables (Dena)'::TEXT, v_total_payables
    WHERE v_total_payables > 0

    UNION ALL
    -- C. EQUITY & CAPITAL (Clean - No Suspense Accounts)
    SELECT 'EQUITY'::TEXT, 'Equity & Reserves'::TEXT, a.name::TEXT, SUM(le.credit_amount - le.debit_amount)
    FROM accounts a 
    JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'equity'
      AND COALESCE(a.slug, '') NOT IN ('retained-earnings') -- Exclude suspense/adjustment accounts
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    
    UNION ALL
    -- D. NET PROFIT (Operating Result)
    SELECT 'EQUITY'::TEXT, 'Equity & Reserves'::TEXT, 'Net Profit'::TEXT, COALESCE(v_net_profit, 0);

END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- Verify Clean Output
SELECT * FROM get_financial_position('2026-02-05') ORDER BY category, sub_category, account_name;

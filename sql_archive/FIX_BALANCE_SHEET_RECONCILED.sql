-- FIX BALANCE SHEET WITH AR/AP CONTROL RECONCILIATION
-- Purpose: Include AR/AP orphan balances to maintain accounting equation balance.

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
    v_ar_control_balance NUMERIC;
    v_ap_control_balance NUMERIC;
    v_ar_orphan NUMERIC;
    v_ap_orphan NUMERIC;
BEGIN
    -- 1. Net Profit
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

    -- 2. Party Balances
    SELECT COALESCE(SUM(receivable_balance), 0), COALESCE(SUM(payable_balance), 0)
    INTO v_total_receivables, v_total_payables
    FROM get_market_position_report(p_date);

    -- 3. AR/AP Control Account Balances
    SELECT COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    INTO v_ar_control_balance
    FROM accounts a
    LEFT JOIN ledger_entries le ON a.id = le.account_id AND le.posting_date <= p_date
    WHERE a.slug IN ('ar', 'accounts_receivable')
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    SELECT COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    INTO v_ap_control_balance
    FROM accounts a
    LEFT JOIN ledger_entries le ON a.id = le.account_id AND le.posting_date <= p_date
    WHERE a.slug IN ('ap', 'accounts_payable')
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    -- 4. Calculate Orphan Balances
    v_ar_orphan := v_ar_control_balance - v_total_receivables;
    v_ap_orphan := ABS(v_ap_control_balance) - v_total_payables;

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
    -- A2. Market Receivables
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
    -- B2. Supplier Payables
    SELECT 'LIABILITIES'::TEXT, 'Liabilities'::TEXT, 'Total Supplier Payables (Dena)'::TEXT, v_total_payables
    WHERE v_total_payables > 0

    UNION ALL
    -- B3. AP Control Account Orphan (Suspense)
    SELECT 'LIABILITIES'::TEXT, 'Liabilities'::TEXT, 'AP Control Reconciliation (Suspense)'::TEXT, v_ap_orphan
    WHERE v_ap_orphan > 100

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
    SELECT 'EQUITY'::TEXT, 'Equity & Reserves'::TEXT, 'Net Profit'::TEXT, COALESCE(v_net_profit, 0)

    UNION ALL
    -- E. AR Control Account Orphan (Negative Equity / Adjustment)
    SELECT 'EQUITY'::TEXT, 'Equity & Reserves'::TEXT, 'AR Control Reconciliation (Suspense)'::TEXT, -v_ar_orphan
    WHERE v_ar_orphan > 100;

END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

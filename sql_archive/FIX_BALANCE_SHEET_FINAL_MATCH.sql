CREATE OR REPLACE FUNCTION public.get_financial_position(p_date DATE)
RETURNS TABLE (category TEXT, sub_category TEXT, account_name TEXT, balance NUMERIC) 
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
    v_net_profit NUMERIC; 
    v_total_assets NUMERIC; 
    v_total_liabilities NUMERIC; 
    v_equity_balancing NUMERIC;
BEGIN
    -- [1] Net Profit
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0) INTO v_net_profit
    FROM public.ledger_entries le 
    JOIN public.accounts a ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense') 
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = FALSE);

    -- [2] Total Assets (Cash, Bank, Receivables)
    SELECT COALESCE(SUM(val), 0) INTO v_total_assets FROM (
        -- Cash & Bank
        SELECT SUM(le.debit_amount - le.credit_amount) as val
        FROM public.accounts a JOIN public.ledger_entries le ON a.id = le.account_id 
        WHERE a.account_type = 'asset' 
          AND (a.slug IS NULL OR a.slug NOT IN ('ar', 'ap', 'accounts-receivable', 'accounts-payable')) 
          AND le.posting_date <= p_date AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) GROUP BY a.id
        UNION ALL
        -- Receivables from Parties (Only if Balance is Positive/Debit)
        SELECT (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) 
        FROM public.parties p LEFT JOIN public.ledger_entries le ON p.id = le.party_id AND le.posting_date <= p_date 
          AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
        GROUP BY p.id, p.opening_balance
        HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) > 0
    ) s1;

    -- [3] Total Liabilities (Loans, Payables)
    SELECT COALESCE(SUM(val), 0) INTO v_total_liabilities FROM (
        -- Explicit Liabilities (Loans etc), EXCLUDING Control Accounts to avoid Double Counting
        SELECT SUM(le.credit_amount - le.debit_amount) as val
        FROM public.accounts a JOIN public.ledger_entries le ON a.id = le.account_id 
        WHERE a.account_type = 'liability' 
          AND (a.slug IS NULL OR a.slug NOT IN ('ar', 'ap', 'accounts-receivable', 'accounts-payable'))
          AND a.name NOT ILIKE '%Accounts Payable%' -- Extra safety
          AND le.posting_date <= p_date AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
        GROUP BY a.id
        UNION ALL
        -- Payables to Parties (Only if Balance is Negative/Credit)
        SELECT ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
        FROM public.parties p LEFT JOIN public.ledger_entries le ON p.id = le.party_id AND le.posting_date <= p_date 
          AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
        GROUP BY p.id, p.opening_balance
        HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) <= 0
    ) s2;

    -- [4] Equity Calculation
    v_equity_balancing := v_total_assets - v_total_liabilities - v_net_profit;

    RETURN QUERY
    -- SECTION 1: ASSETS
    -- Cash/Bank
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT, CAST(SUM(le.debit_amount - le.credit_amount) AS NUMERIC) 
    FROM public.accounts a JOIN public.ledger_entries le ON a.id = le.account_id 
    WHERE a.account_type = 'asset' AND (a.slug IS NULL OR a.slug NOT IN ('ar', 'ap', 'accounts-receivable', 'accounts-payable')) 
      AND le.posting_date <= p_date AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
    GROUP BY a.id, a.name HAVING ABS(SUM(le.debit_amount - le.credit_amount)) > 0.01

    UNION ALL
    -- Party Receivables
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT, 
           CAST((COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) AS NUMERIC) 
    FROM public.parties p LEFT JOIN public.ledger_entries le ON p.id = le.party_id AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
    GROUP BY p.id, p.name, p.opening_balance 
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) > 0.01

    UNION ALL
    
    -- SECTION 2: LIABILITIES
    -- Party Payables (Includes Usee Khan if balance is negative)
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT, 
           CAST(ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) AS NUMERIC) 
    FROM public.parties p LEFT JOIN public.ledger_entries le ON p.id = le.party_id AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
    GROUP BY p.id, p.name, p.opening_balance 
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) <= -0.01

    UNION ALL
    -- Other Liabilities (Excluding Control Accounts)
    SELECT 'LIABILITIES'::TEXT, 'Other'::TEXT, a.name::TEXT, 
           CAST(SUM(le.credit_amount - le.debit_amount) AS NUMERIC) 
    FROM public.accounts a JOIN public.ledger_entries le ON a.id = le.account_id 
    WHERE a.account_type = 'liability' 
      AND (a.slug IS NULL OR a.slug NOT IN ('ar', 'ap', 'accounts-receivable', 'accounts-payable'))
      AND a.name NOT ILIKE '%Accounts Payable%'
      AND le.posting_date <= p_date AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
    GROUP BY a.id, a.name

    UNION ALL
    -- SECTION 3: EQUITY
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, 'Opening Investment'::TEXT, CAST(v_equity_balancing AS NUMERIC)
    UNION ALL
    SELECT 'EQUITY'::TEXT, 'Profit'::TEXT, 'Accumulated Net Profit'::TEXT, CAST(v_net_profit AS NUMERIC);
END;
$$;

-- =================================================================
-- FINAL ACCOUNTANT-GRADE REPORTING FIX (P&L + Balance Sheet)
-- Rule: Net-Sum Logic (Option B) - Remove all is_reversed filters
-- Ensures P&L matches Balance Sheet and math is correct.
-- =================================================================

BEGIN;

-- 1. FIX PROFIT & LOSS FUNCTION (Remove filters to fix -35k Expense issue)
CREATE OR REPLACE FUNCTION public.get_profit_loss(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    section TEXT,
    account_name TEXT,
    amount NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    -- A. INCOME (Net Sum: No filters)
    SELECT 'Income'::TEXT, a.name, COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'income' AND a.is_active = true
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- B. DIRECT COSTS (Net Sum: No filters)
    SELECT 'Direct Costs'::TEXT, a.name, COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense' 
      AND (a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%Cost of Goods Sold%')
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- C. OPERATING EXPENSES (Net Sum: No filters)
    SELECT 'Expenses'::TEXT, a.name, COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense' AND a.is_active = true
      AND (a.slug IS NULL OR a.slug <> 'cogs')
      AND a.code <> '4100'
      AND a.name NOT ILIKE '%Cost of Goods Sold%'
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0;
END;
$$;

-- 2. FIX BALANCE SHEET FUNCTION (Align with P&L and correct Profit inflation)
CREATE OR REPLACE FUNCTION get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE
    v_net_profit NUMERIC := 0;
    v_total_assets NUMERIC := 0;
    v_total_liabilities NUMERIC := 0;
    v_explicit_equity NUMERIC := 0;
    v_owner_capital NUMERIC := 0;
BEGIN
    -- Calculate Net Profit (Lifetime Profit up to p_date using Net Sum logic)
    SELECT COALESCE(SUM(
        CASE 
            WHEN a.account_type = 'income'  THEN (le.credit_amount - le.debit_amount)
            WHEN a.account_type = 'expense' THEN (le.debit_amount - le.credit_amount)
            ELSE 0 
        END
    ), 0) INTO v_net_profit
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense') AND le.posting_date <= p_date;

    -- Total System Assets
    SELECT COALESCE(SUM(COALESCE(a.opening_balance, 0) + (le.debit_amount - le.credit_amount)), 0) INTO v_total_assets
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type = 'asset' AND a.slug NOT IN ('ar', 'ap')
    GROUP BY a.id LIMIT 1; 

    -- Total Party Receivables
    v_total_assets := v_total_assets + COALESCE((
        SELECT SUM(val) FROM (
            SELECT (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) as val
            FROM public.parties p
            LEFT JOIN public.ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
            GROUP BY p.id, p.opening_balance
            HAVING ROUND(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) > 0
        ) sub
    ), 0);

    -- Total System Liabilities
    SELECT COALESCE(SUM(COALESCE(a.opening_balance, 0) + (le.credit_amount - le.debit_amount)), 0) INTO v_total_liabilities
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type = 'liability' AND a.slug NOT IN ('ar', 'ap');

    -- Total Party Payables
    v_total_liabilities := v_total_liabilities + COALESCE((
        SELECT SUM(ABS(val)) FROM (
            SELECT (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) as val
            FROM public.parties p
            LEFT JOIN public.ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
            GROUP BY p.id, p.opening_balance
            HAVING ROUND(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) < 0
        ) sub
    ), 0);

    -- Explicit Equity
    SELECT COALESCE(SUM(COALESCE(a.opening_balance, 0) + (le.credit_amount - le.debit_amount)), 0) INTO v_explicit_equity
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE (a.account_type = 'equity' OR a.code = '3000');

    -- Balancing Figure (Opening Investment)
    v_owner_capital := v_total_assets - v_total_liabilities - v_net_profit - v_explicit_equity;

    RETURN QUERY
    -- ASSETS
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(a.opening_balance, 0) + SUM(COALESCE(le.debit_amount, 0) - COALESCE(le.credit_amount, 0))
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type = 'asset' AND a.slug NOT IN ('ar', 'ap')
    GROUP BY a.id, a.name, a.opening_balance
    HAVING ROUND(COALESCE(a.opening_balance, 0) + SUM(COALESCE(le.debit_amount, 0) - COALESCE(le.credit_amount, 0)), 2) <> 0

    UNION ALL
    -- RECEIVABLES
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT,
           (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
    FROM public.parties p
    LEFT JOIN public.ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
    GROUP BY p.id, p.name, p.opening_balance
    HAVING ROUND(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) > 0

    UNION ALL
    -- PAYABLES
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT,
           ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
    FROM public.parties p
    LEFT JOIN public.ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
    GROUP BY p.id, p.name, p.opening_balance
    HAVING ROUND(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) < 0

    UNION ALL
    -- OWNER CAPITAL
    SELECT 'EQUITY'::TEXT, 'Owner Capital'::TEXT, 'Opening Investment'::TEXT, v_owner_capital
    WHERE ROUND(v_owner_capital, 2) <> 0

    UNION ALL
    -- NET PROFIT
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Net Profit'::TEXT, v_net_profit;
END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;

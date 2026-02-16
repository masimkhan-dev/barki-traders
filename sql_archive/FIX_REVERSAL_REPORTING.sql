-- =================================================================
-- REVERSAL HANDLING FIX
-- Purpose: Ensure high-level reports (P&L, Balance Sheet) handle 
--          reversals consistently by including both sides or excluding both.
-- =================================================================

BEGIN;

-- 1. UPDATE BALANCE SHEET FUNCTION
CREATE OR REPLACE FUNCTION public.get_balance_sheet(
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
    -- Calculate Net Profit (Income - Expenses)
    -- REMOVED: is_reversed = false filter to allow matching pairs to cancel out
    SELECT 
        COALESCE(SUM(
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
      AND (le.is_reversed IS NULL OR le.is_reversed = false OR le.voucher_no LIKE 'REV-%'); 
      -- Logic: If we include REV-, we MUST also include the original reversed entry for balance.

    -- Return Assets
    RETURN QUERY
    SELECT 
        'Assets'::TEXT as section,
        a.name as account_name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as amount
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
    WHERE a.account_type = 'asset'
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    UNION ALL
    
    -- Return Liabilities
    SELECT 
        'Liabilities'::TEXT as section,
        a.name as account_name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0) as amount
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
    WHERE a.account_type = 'liability'
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- Return Equity
    SELECT 
        'Equity'::TEXT as section,
        a.name as account_name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0) as amount
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
    WHERE a.account_type = 'equity'
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- Add Net Profit
    SELECT 
        'Equity'::TEXT as section,
        'Net Profit (Current Period)'::TEXT as account_name,
        v_net_profit as amount
    WHERE v_net_profit <> 0
    
    ORDER BY section DESC, account_name;
END;
$$;

-- 2. UPDATE PROFIT & LOSS FUNCTION
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
    -- Income Section
    SELECT 
        CASE 
            WHEN a.code = '5000' THEN 'Direct Costs'
            WHEN a.account_type = 'income' THEN 'Income'
            ELSE 'Other'
        END::TEXT as section,
        a.name as account_name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0) as amount
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        -- We include ALL entries (even reversed) in totals so they cancel perfectly
        AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
        AND le.posting_date <= p_end_date
    WHERE a.account_type = 'income'
      AND a.is_active = true
    GROUP BY a.id, a.name, a.code
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- Expense Section
    SELECT 
        'Operating Expenses'::TEXT as section,
        a.name as account_name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as amount
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
        AND le.posting_date <= p_end_date
    WHERE a.account_type = 'expense'
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    ORDER BY section DESC, account_name;
END;
$$;

COMMIT;

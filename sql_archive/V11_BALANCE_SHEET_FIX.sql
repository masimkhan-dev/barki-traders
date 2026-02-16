-- V11 BALANCE SHEET FIX (AUDIT STANDARD)
-- Purpose: Correct Net Profit mismatch by ensuring reversed entries are excluded.

BEGIN;

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
BEGIN
    -- 1. Correct Net Profit Calculation (Matches get_profit_loss_v11 logic)
    -- We filter out entries where is_reversed is true
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

    RETURN QUERY
    -- A. ASSETS (Cash, Bank, and Positive Receivables)
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT, COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM accounts a 
    LEFT JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE (a.account_type::TEXT ILIKE 'asset' OR a.code = '1100')
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name 
    HAVING (a.code IN ('1000', '1010')) -- Always show Cash/Bank
        OR (SUM(le.debit_amount - le.credit_amount) > 0); -- Show others only if positive

    UNION ALL
    -- B. LIABILITIES (Payables and Negative Receivables)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a 
    JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE (a.account_type::TEXT ILIKE 'liability' OR a.code IN ('2000', '1100'))
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name 
    HAVING (a.code = '1100' AND SUM(le.debit_amount - le.credit_amount) < 0) -- Advance customer payments
        OR (a.code != '1100' AND SUM(le.debit_amount - le.credit_amount) != 0 AND (a.account_type::TEXT ILIKE 'liability' OR a.code = '2000'))

    UNION ALL
    -- C. EQUITY & CAPITAL
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name::TEXT, ABS(SUM(le.credit_amount - le.debit_amount))
    FROM accounts a 
    JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'equity'
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    
    UNION ALL
    -- D. RETAINED EARNINGS (Accumulated Profit)
    SELECT 'EQUITY'::TEXT, 'Profit/Loss'::TEXT, 'Net Profit'::TEXT, COALESCE(v_net_profit, 0);

END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMIT;

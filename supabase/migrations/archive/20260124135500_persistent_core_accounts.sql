-- Phase 14: PERSISTENT CORE ACCOUNTS IN BALANCE SHEET
-- -----------------------------------------------------------------
-- Ensures that Cash, Bank, and Accounts Receivable always appear 
-- in the Balance Sheet even if their balance is Zero.

BEGIN;

CREATE OR REPLACE FUNCTION get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE v_net_profit NUMERIC;
BEGIN
    -- Historical Profit Calculation
    SELECT COALESCE((
        SELECT SUM(le.credit_amount - le.debit_amount) 
        FROM accounts a 
        JOIN ledger_entries le ON le.account_id = a.id 
        WHERE a.account_type::TEXT ILIKE 'income' AND le.posting_date <= p_date
    ), 0)
    - COALESCE((
        SELECT SUM(le.debit_amount - le.credit_amount) 
        FROM accounts a 
        JOIN ledger_entries le ON le.account_id = a.id 
        WHERE a.account_type::TEXT ILIKE 'expense' AND le.posting_date <= p_date
    ), 0)
    INTO v_net_profit;

    RETURN QUERY
    -- A. ASSETS (Cash, Bank, and Positive Receivables)
    -- We use >= 0 for core accounts (1000, 1010) to ensure they always show up
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT, COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM accounts a 
    LEFT JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE (a.account_type::TEXT ILIKE 'asset' OR a.code = '1100')
      AND a.code IN ('1000', '1010', '1100') -- Core Asset Accounts
    GROUP BY a.id, a.name 
    HAVING (a.code IN ('1000', '1010')) -- Always show Cash/Bank
        OR (SUM(le.debit_amount - le.credit_amount) > 0) -- Show others only if positive

    UNION ALL
    -- B. LIABILITIES (Payables and Negative Receivables)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a 
    JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE (a.account_type::TEXT ILIKE 'liability' OR a.code IN ('2000', '1100'))
    GROUP BY a.id, a.name 
    HAVING (a.code = '1100' AND SUM(le.debit_amount - le.credit_amount) < 0) -- Advance customer payments
        OR (a.code != '1100' AND SUM(le.debit_amount - le.credit_amount) != 0 AND (a.account_type::TEXT ILIKE 'liability' OR a.code = '2000'))

    UNION ALL
    -- C. EQUITY & CAPITAL
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a 
    JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'equity'
    GROUP BY a.id, a.name
    
    UNION ALL
    -- D. RETAINED EARNINGS (Accumulated Profit)
    SELECT 'EQUITY'::TEXT, 'Profit/Loss'::TEXT, 'Accumulated Profit/(Loss)'::TEXT, COALESCE(v_net_profit, 0);

END;
$$ LANGUAGE plpgsql;

COMMIT;

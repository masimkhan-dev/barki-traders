-- Phase 13: SMART BALANCE SHEET CLASSIFICATION
-- -----------------------------------------------------------------
-- Forces accounts to switch sides based on their sign (Net Debit to Assets, Net Credit to Liabilities)
-- This fixes the "Negative Asset" issue and matches the owner's preference.

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
    -- Historical Profit Calculation (Sales - Purchases - Expenses)
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
    -- A. ASSETS (Anything with a net Debit balance that is classified as asset/receivable)
    -- We filter for sign > 0 to keep Assets side positive
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT, SUM(le.debit_amount - le.credit_amount)
    FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
    WHERE le.posting_date <= p_date 
      AND (a.account_type::TEXT ILIKE 'asset' OR a.code = '1100')
      AND a.code NOT IN ('1200')
    GROUP BY a.id, a.name 
    HAVING SUM(le.debit_amount - le.credit_amount) > 0

    UNION ALL
    -- B. LIABILITIES (Includes Payables AND any Receivables with a net Credit balance)
    -- This handles the case where a customer has paid more than they owe (Advance)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
    WHERE le.posting_date <= p_date 
      AND (a.account_type::TEXT ILIKE 'liability' OR a.code IN ('2000', '1100'))
    GROUP BY a.id, a.name 
    HAVING (a.code = '1100' AND SUM(le.debit_amount - le.credit_amount) < 0)
        OR (a.code != '1100' AND SUM(le.debit_amount - le.credit_amount) != 0 AND (a.account_type::TEXT ILIKE 'liability' OR a.code = '2000'))

    UNION ALL
    -- C. EQUITY & CAPITAL
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
    WHERE le.posting_date <= p_date AND a.account_type::TEXT ILIKE 'equity'
    GROUP BY a.id, a.name
    
    UNION ALL
    -- D. RETAINED EARNINGS (Accumulated Profit)
    SELECT 'EQUITY'::TEXT, 'Profit/Loss'::TEXT, 'Accumulated Profit/(Loss)'::TEXT, COALESCE(v_net_profit, 0);

END;
$$ LANGUAGE plpgsql;

COMMIT;

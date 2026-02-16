-- Phase 12: FINANCIAL SIMPLIFICATION (REVERT STOCK FROM BALANCE SHEET)
-- -----------------------------------------------------------------
-- This migration removes "Fuel Stock Value" from the Balance Sheet 
-- but keeps the professional Gold Standard accounting logic from Phase 9 and 10.

BEGIN;

-- 1. Make stock valuation return 0 (Disabling the feature)
CREATE OR REPLACE FUNCTION get_historical_stock_value(p_date DATE)
RETURNS NUMERIC AS $$
BEGIN
    RETURN 0;
END;
$$ LANGUAGE plpgsql STABLE;


-- 2. Update Financial Position Report (Balance Sheet)
-- This version removes the INVENTORY section to ensure Assets = Liabilities + Equity
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
    -- A. ASSETS (Cash & Bank & Receivables)
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT, SUM(le.debit_amount - le.credit_amount)
    FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
    WHERE le.posting_date <= p_date 
      AND (a.account_type::TEXT ILIKE 'asset' OR a.code = '1100') 
      AND a.code NOT IN ('1200') -- Exclude Inventory asset for now as per revert
    GROUP BY a.id, a.name HAVING SUM(le.debit_amount - le.credit_amount) != 0

    UNION ALL
    -- B. LIABILITIES (Including Payables 2000)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
    WHERE le.posting_date <= p_date 
      AND (a.account_type::TEXT ILIKE 'liability' OR a.code = '2000')
    GROUP BY a.id, a.name HAVING SUM(le.debit_amount - le.credit_amount) != 0

    UNION ALL
    -- C. EQUITY & CAPITAL
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
    WHERE le.posting_date <= p_date AND a.account_type::TEXT ILIKE 'equity'
    GROUP BY a.id, a.name
    
    UNION ALL
    -- D. RETAINED EARNINGS (Accumulated Profit)
    SELECT 'EQUITY'::TEXT, 'Profit/Loss'::TEXT, 'Accumulated Net Profit/(Loss)'::TEXT, COALESCE(v_net_profit, 0);

END;
$$ LANGUAGE plpgsql;

COMMIT;

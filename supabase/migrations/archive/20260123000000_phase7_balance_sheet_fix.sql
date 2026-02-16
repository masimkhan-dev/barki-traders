-- 20260123000000_phase7_balance_sheet_fix.sql
-- Fixes the Balance Sheet RPC to strictly follow the Double Entry System (Assets = Liabilities + Equity)
-- Dynamic calculation of Net Profit (Retained Earnings) ensures the sheet balances.

BEGIN;

-- 1. Drop the existing (flawed) function
DROP FUNCTION IF EXISTS get_balance_sheet(DATE);

-- 2. Validate Parties and Ledger Entries (Double check indices)
CREATE INDEX IF NOT EXISTS idx_ledger_party_posting ON ledger_entries(party_id, posting_date);
CREATE INDEX IF NOT EXISTS idx_ledger_account_posting ON ledger_entries(account_id, posting_date);

-- 3. Create the robust Balance Sheet RPC
CREATE OR REPLACE FUNCTION get_balance_sheet(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE
    v_net_profit NUMERIC;
    v_total_income NUMERIC;
    v_total_expense NUMERIC;
BEGIN
    -- A. Calculate Net Profit (Income - Expense) up to p_date for Retained Earnings
    -- ---------------------------------------------------------------------------
    -- Income (Credit Balance is positive result here)
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_total_income
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'income' AND le.posting_date <= p_date;

    -- Expense (Debit Balance is positive result here)
    SELECT COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    INTO v_total_expense
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense' AND le.posting_date <= p_date;

    v_net_profit := v_total_income - v_total_expense;


    RETURN QUERY
    -- 1. ASSETS: Cash, Bank, & Other Asset Accounts
    -- ---------------------------------------------------------------------------
    SELECT 'ASSETS'::TEXT, 'Current Assets'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0) AS bal
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND le.posting_date <= p_date
      AND a.code NOT IN ('1100', '1200', '1100-system') -- Exclude generic Control Accounts if used
    GROUP BY a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0

    UNION ALL

    -- 2. ASSETS: Fuel Inventory (Account 1200)
    -- ---------------------------------------------------------------------------
    SELECT 'ASSETS'::TEXT, 'Inventory'::TEXT, 'Fuel Stock Value'::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.code = '1200'
      AND le.posting_date <= p_date
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0

    UNION ALL

    -- 3. ASSETS: Receivables (Parties with Debit Balance)
    -- ---------------------------------------------------------------------------
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT,
           -- Add opening balance if it exists in parties table and NOT in ledger (to avoid double count if ledger has it)
           -- Assuming ledger is the source of truth now.
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM parties p
    JOIN ledger_entries le ON le.party_id = p.id
    WHERE le.posting_date <= p_date
    GROUP BY p.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) > 0

    UNION ALL

    -- 4. LIABILITIES: Payables (Parties with Credit Balance)
    -- ---------------------------------------------------------------------------
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT,
           ABS(COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
    FROM parties p
    JOIN ledger_entries le ON le.party_id = p.id
    WHERE le.posting_date <= p_date
    GROUP BY p.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) < 0

    UNION ALL

    -- 5. LIABILITIES: Other Liability Accounts
    -- ---------------------------------------------------------------------------
    SELECT 'LIABILITIES'::TEXT, 'Current Liabilities'::TEXT, a.name::TEXT,
           ABS(COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND le.posting_date <= p_date
      AND a.code NOT IN ('2000') -- Exclude Control Account
    GROUP BY a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0

    UNION ALL

    -- 6. EQUITY: Capital / Owner Equity
    -- ---------------------------------------------------------------------------
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name::TEXT,
           ABS(COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'equity'
      AND le.posting_date <= p_date
    GROUP BY a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0

    UNION ALL

    -- 7. EQUITY: Retained Earnings (Net Profit)
    -- ---------------------------------------------------------------------------
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Net Profit / (Loss)'::TEXT,
           v_net_profit; -- Positive v_net_profit means Credit Balance (Profit), which adds to Equity.

END;
$$ LANGUAGE plpgsql;

-- 4. Permissions
GRANT EXECUTE ON FUNCTION get_balance_sheet(DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION get_balance_sheet(DATE) TO service_role;

COMMIT;

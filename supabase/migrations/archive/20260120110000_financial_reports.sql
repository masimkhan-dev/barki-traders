-- MUNSHI FINANCIAL REPORTS (Trial Balance & Balance Sheet)
-- This migration adds the core reporting logic for the Unified Parties system.

BEGIN;

-- 1. RPC: GET TRIAL BALANCE
-- Returns a list of all accounts and parties with opening, transactions, and closing balances.
DROP FUNCTION IF EXISTS get_trial_balance(date, date);
CREATE OR REPLACE FUNCTION get_trial_balance(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    opening_balance NUMERIC,
    debit_total NUMERIC,
    credit_total NUMERIC,
    closing_balance NUMERIC,
    is_party BOOLEAN
) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    -- A. General Ledger Accounts
    SELECT 
        a.code as account_code,
        a.name as account_name,
        -- Opening: Sum of all entries before start_date
        COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date < p_start_date), 0) as opening_balance,
        -- Period Debit
        COALESCE((SELECT SUM(debit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) as debit_total,
        -- Period Credit
        COALESCE((SELECT SUM(credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) as credit_total,
        -- Closing: Opening + Debit - Credit
        0::NUMERIC as closing_balance, -- Calculated in next step
        false as is_party
    FROM accounts a
    WHERE a.is_active = true

    UNION ALL

    -- B. Parties (Customers/Suppliers)
    SELECT 
        'PTY' as account_code, -- Placeholder
        p.name as account_name,
        -- Opening: p.opening_balance + all entries before start_date
        COALESCE(p.opening_balance, 0) + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date < p_start_date), 0) as opening_balance,
        -- Period Debit
        COALESCE((SELECT SUM(debit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) as debit_total,
        -- Period Credit
        COALESCE((SELECT SUM(credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) as credit_total,
        -- Closing
        0::NUMERIC as closing_balance,
        true as is_party
    FROM parties p
    WHERE p.is_active = true;

    -- Note: Closing balance is calculated in the final selection to ensure formula consistency: Closing = Opening + Debit - Credit
END;
$$;

-- Refined Trial Balance to include closing calculation in the return
DROP FUNCTION IF EXISTS get_trial_balance_v2(date, date);
CREATE OR REPLACE FUNCTION get_trial_balance_v2(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    opening_balance NUMERIC,
    debit_total NUMERIC,
    credit_total NUMERIC,
    closing_balance NUMERIC
) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    WITH base_data AS (
        -- Accounts
        SELECT 
            a.code,
            a.name,
            COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date < p_start_date), 0) as opening,
            COALESCE((SELECT SUM(debit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) as debit,
            COALESCE((SELECT SUM(credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) as credit
        FROM accounts a
        WHERE a.is_active = true
        
        UNION ALL

        -- Parties
        SELECT 
            CASE WHEN p.type = 'customer' THEN 'CUST' ELSE 'SUPP' END as code,
            p.name,
            COALESCE(p.opening_balance, 0) + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date < p_start_date), 0) as opening,
            COALESCE((SELECT SUM(debit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) as debit,
            COALESCE((SELECT SUM(credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) as credit
        FROM parties p
        WHERE p.is_active = true
    )
    SELECT 
        b.code,
        b.name,
        b.opening,
        b.debit,
        b.credit,
        (b.opening + b.debit - b.credit) as closing
    FROM base_data b
    WHERE ABS(b.opening) > 0 OR ABS(b.debit) > 0 OR ABS(b.credit) > 0;
END;
$$;


-- 2. RPC: GET BALANCE SHEET
DROP FUNCTION IF EXISTS get_balance_sheet(date);
CREATE OR REPLACE FUNCTION get_balance_sheet(p_date DATE)
RETURNS TABLE (
    category TEXT, -- Assets, Liabilities, Equity
    sub_category TEXT, -- Current Assets, Fixed Assets, etc.
    account_name TEXT,
    balance NUMERIC
) LANGUAGE plpgsql AS $$
BEGIN
    -- ASSETS
    RETURN QUERY
    SELECT 'ASSETS'::TEXT, a.account_type::TEXT, a.name, COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date <= p_date), 0)
    FROM accounts a WHERE a.account_type = 'asset' AND a.is_active = true;

    -- Party Assets (Customers with Debit Balance)
    RETURN QUERY
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name, (p.opening_balance + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date <= p_date), 0))
    FROM parties p WHERE p.is_active = true AND (p.opening_balance + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date <= p_date), 0)) > 0;

    -- LIABILITIES
    RETURN QUERY
    SELECT 'LIABILITIES'::TEXT, a.account_type::TEXT, a.name, ABS(COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date <= p_date), 0))
    FROM accounts a WHERE a.account_type = 'liability' AND a.is_active = true;

    -- Party Liabilities (Suppliers/Customers with Credit Balance)
    RETURN QUERY
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name, ABS(p.opening_balance + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date <= p_date), 0))
    FROM parties p WHERE p.is_active = true AND (p.opening_balance + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date <= p_date), 0)) < 0;

    -- EQUITY
    RETURN QUERY
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name, ABS(COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date <= p_date), 0))
    FROM accounts a WHERE a.account_type = 'equity' AND a.is_active = true;

    -- Retained Earnings (Profit/Loss check)
    -- We can calculate this as (Total Sales - Total Expenses - Cogs) but for a simple Balance Sheet, it's often the plug figure or calculated from revenue/expense accounts.
    -- For this Munshi system, let's just sum all revenue and expense codes before p_date.
    RETURN QUERY
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Inappropriate Profit'::TEXT, ABS(COALESCE((SELECT SUM(credit_amount - debit_amount) FROM ledger_entries le JOIN accounts a ON le.account_id = a.id WHERE a.account_type IN ('revenue', 'expense') AND posting_date <= p_date), 0));

END;
$$;

COMMIT;

-- 20260122000000_restore_missing_rpcs.sql
-- Migration to restore missing RPCs (get_stock_movement) and fix get_balance_sheet logic.
-- Run this migration after applying previous migrations.

BEGIN;

-- 1. Create or replace get_stock_movement RPC
-- Returns fuel type wise stock movement between dates.
-- Opening stock is calculated from all purchases minus all sales before the start date.
-- Drop existing version first (may have different return type)
DROP FUNCTION IF EXISTS get_stock_movement(DATE, DATE);
CREATE OR REPLACE FUNCTION get_stock_movement(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    fuel_name TEXT,
    opening_stock NUMERIC,
    purchased NUMERIC,
    sold NUMERIC,
    closing_stock NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        f.name,
        -- Opening stock = Total purchases before start date - Total sales before start date
        COALESCE((SELECT SUM(quantity) FROM purchases WHERE fuel_type_id = f.id AND purchase_date < p_start_date), 0) -
        COALESCE((SELECT SUM(quantity) FROM sales WHERE fuel_type_id = f.id AND sale_date < p_start_date), 0) AS opening,
        -- Purchases in the date range
        COALESCE((SELECT SUM(quantity) FROM purchases WHERE fuel_type_id = f.id AND purchase_date BETWEEN p_start_date AND p_end_date), 0) AS purchased,
        -- Sales in the date range
        COALESCE((SELECT SUM(quantity) FROM sales WHERE fuel_type_id = f.id AND sale_date BETWEEN p_start_date AND p_end_date), 0) AS sold,
        -- Closing stock = Total purchases up to end date - Total sales up to end date
        (COALESCE((SELECT SUM(quantity) FROM purchases WHERE fuel_type_id = f.id AND purchase_date <= p_end_date), 0) -
         COALESCE((SELECT SUM(quantity) FROM sales WHERE fuel_type_id = f.id AND sale_date <= p_end_date), 0)) AS closing
    FROM fuel_types f;
END;
$$ LANGUAGE plpgsql;

-- 2. Fix get_balance_sheet logic (recreate with COALESCE for safety)
DROP FUNCTION IF EXISTS get_balance_sheet(DATE);
CREATE OR REPLACE FUNCTION get_balance_sheet(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    -- Assets from accounts
    SELECT 'ASSETS'::TEXT, a.account_type::TEXT, a.name::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0) AS bal
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND le.posting_date <= p_date
      AND a.code NOT IN ('1100')
    GROUP BY a.account_type, a.name

    UNION ALL
    -- Receivables from parties (customers)
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT,
           COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM parties p
    LEFT JOIN ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
    WHERE p.type = 'customer'
    GROUP BY p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) <> 0

    UNION ALL
    -- Liabilities from accounts
    SELECT 'LIABILITIES'::TEXT, a.account_type::TEXT, a.name::TEXT,
           ABS(COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) AS bal
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND le.posting_date <= p_date
      AND a.code NOT IN ('2000')
    GROUP BY a.account_type, a.name

    UNION ALL
    -- Payables to parties (suppliers)
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT,
           ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
    FROM parties p
    LEFT JOIN ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
    WHERE p.type = 'supplier'
    GROUP BY p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) <> 0

    UNION ALL
    -- Equity
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name::TEXT,
           ABS(COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) AS bal
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'equity'
      AND le.posting_date <= p_date
    GROUP BY a.name;
END;
$$ LANGUAGE plpgsql;

COMMIT;

-- Notify PostgREST to reload configuration (if using PostgREST)
NOTIFY pgrst, 'reload config';

-- ========================================
-- REPORTING FUNCTIONS (Ledger-Driven)
-- Migration: 20260114000003_reporting_functions.sql
-- ========================================

-- 1. Helper function to check if account is Asset/Expense (Debit normal) vs Liability/Equity/Income (Credit normal)
-- Not strictly needed if we just return Dr/Cr totals.

-- 2. Customer Ledger Statement
CREATE OR REPLACE FUNCTION get_customer_ledger_statement(target_customer_id UUID)
RETURNS TABLE (
    entry_id UUID,
    posting_date DATE,
    voucher_no TEXT,
    voucher_type TEXT,
    narration TEXT,
    debit_amount NUMERIC,
    credit_amount NUMERIC,
    account_code TEXT,
    account_name TEXT,
    reference_id UUID
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
    SELECT 
        le.id,
        le.posting_date,
        le.voucher_no,
        le.voucher_type,
        le.narration,
        le.debit_amount,
        le.credit_amount,
        a.code,
        a.name,
        le.reference_id
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    LEFT JOIN sales s ON le.reference_type = 'sale' AND le.reference_id = s.id
    LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
    WHERE 
        (s.customer_id = target_customer_id OR p.party_id = target_customer_id)
        AND a.code IN ('1100', '2100') -- AR (Asset) and Customer Advance (Liability)
    ORDER BY le.posting_date, le.created_at;
END;
$$;

-- 3. Supplier Ledger Statement
CREATE OR REPLACE FUNCTION get_supplier_ledger_statement(target_supplier_id UUID)
RETURNS TABLE (
    entry_id UUID,
    posting_date DATE,
    voucher_no TEXT,
    voucher_type TEXT,
    narration TEXT,
    debit_amount NUMERIC,
    credit_amount NUMERIC,
    account_code TEXT,
    account_name TEXT,
    reference_id UUID
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
    SELECT 
        le.id,
        le.posting_date,
        le.voucher_no,
        le.voucher_type,
        le.narration,
        le.debit_amount,
        le.credit_amount,
        a.code,
        a.name,
        le.reference_id
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    LEFT JOIN purchases pu ON le.reference_type = 'purchase' AND le.reference_id = pu.id
    LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
    WHERE 
        (pu.supplier_id = target_supplier_id OR p.party_id = target_supplier_id)
        AND a.code IN ('2000', '1110') -- AP (Liability) and Supplier Advance (Asset)
    ORDER BY le.posting_date, le.created_at;
END;
$$;

-- 4. Trial Balance Function
CREATE OR REPLACE FUNCTION get_trial_balance(start_date DATE DEFAULT NULL, end_date DATE DEFAULT NULL)
RETURNS TABLE (
    account_id UUID,
    account_code TEXT,
    account_name TEXT,
    account_type TEXT,
    total_debit NUMERIC,
    total_credit NUMERIC,
    net_balance NUMERIC
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
    WITH opening_balances AS (
        -- Calculate balances BEFORE start_date (if provided)
        SELECT 
            le.account_id,
            SUM(le.debit_amount) as open_dr,
            SUM(le.credit_amount) as open_cr
        FROM ledger_entries le
        WHERE (start_date IS NULL OR le.posting_date < start_date)
        GROUP BY le.account_id
    ),
    period_activity AS (
        -- Calculate activity WITHIN date range
        SELECT 
            le.account_id,
            SUM(le.debit_amount) as period_dr,
            SUM(le.credit_amount) as period_cr
        FROM ledger_entries le
        WHERE (start_date IS NULL OR le.posting_date >= start_date)
          AND (end_date IS NULL OR le.posting_date <= end_date)
        GROUP BY le.account_id
    )
    SELECT 
        a.id,
        a.code,
        a.name,
        a.account_type,
        COALESCE(ob.open_dr, 0) + COALESCE(pa.period_dr, 0) as total_debit,
        COALESCE(ob.open_cr, 0) + COALESCE(pa.period_cr, 0) as total_credit,
        (COALESCE(ob.open_dr, 0) + COALESCE(pa.period_dr, 0)) - (COALESCE(ob.open_cr, 0) + COALESCE(pa.period_cr, 0)) as net_balance
    FROM accounts a
    LEFT JOIN opening_balances ob ON ob.account_id = a.id
    LEFT JOIN period_activity pa ON pa.account_id = a.id
    WHERE a.is_active = true
    ORDER BY a.code;
END;
$$;

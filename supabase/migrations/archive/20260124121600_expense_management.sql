-- Phase 10: ENHANCED EXPENSE MANAGEMENT ARCHITECTURE
-- -----------------------------------------------------------------
-- 1. Chart of Accounts expansion for operational costs with hierarchy.
-- 2. Enhanced expense posting safety logic with source validation.

BEGIN;

--------------------------------------------------------------------------------
-- 1. EXPAND CHART OF ACCOUNTS (With Hierarchy)
--------------------------------------------------------------------------------
DO $$
DECLARE v_parent_id UUID;
BEGIN
    SELECT id INTO v_parent_id FROM accounts WHERE code = '6000';

    INSERT INTO public.accounts (code, name, account_type, parent_id, is_system, is_active) VALUES
    -- Direct Operating Expenses
    ('6100', 'Electricity Bill', 'expense', v_parent_id, false, true),
    ('6110', 'Generator Fuel', 'expense', v_parent_id, false, true),
    ('6120', 'Station Maintenance', 'expense', v_parent_id, false, true),
    ('6130', 'Janitorial / Cleaning', 'expense', v_parent_id, false, true),
    -- Staff Related
    ('6200', 'Staff Salaries', 'expense', v_parent_id, false, true),
    ('6210', 'Staff Food / Welfare', 'expense', v_parent_id, false, true),
    ('6220', 'Overtime Payments', 'expense', v_parent_id, false, true),
    -- Admin & Misc
    ('6300', 'Printing & Stationery', 'expense', v_parent_id, false, true),
    ('6310', 'Telephone & Internet', 'expense', v_parent_id, false, true),
    ('6320', 'Legal & Audit Fees', 'expense', v_parent_id, false, true),
    ('6999', 'Miscellaneous Expenses', 'expense', v_parent_id, false, true)
    ON CONFLICT (code) DO UPDATE SET parent_id = EXCLUDED.parent_id;
END $$;


--------------------------------------------------------------------------------
-- 2. ENHANCED EXPENSE POSTING HELPER
--------------------------------------------------------------------------------
-- This wrapper ensures expenses are categorized correctly and hit Cash/Bank
CREATE OR REPLACE FUNCTION post_expense_entry(
    p_expense_account_id UUID,
    p_payment_account_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_voucher_no TEXT;
    v_seq_num INT;
    v_result json;
    v_pay_code TEXT;
BEGIN
    -- 1. Validations
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    
    -- Ensure target is actually an Expense account
    IF NOT EXISTS (SELECT 1 FROM accounts WHERE id = p_expense_account_id AND account_type = 'expense') THEN
        RAISE EXCEPTION 'Target account must be an Expense type';
    END IF;

    -- Ensure payment source is Cash (1000) or Bank (1010)
    SELECT code INTO v_pay_code FROM accounts WHERE id = p_payment_account_id;
    IF v_pay_code NOT IN ('1000', '1010') THEN
        RAISE EXCEPTION 'Payment Source must be Cash (1000) or Bank (1010)';
    END IF;

    -- 2. Atomic Voucher Generation (EXP-YYYYMMDD-SEQ)
    SELECT COALESCE(COUNT(*), 0) + 1 INTO v_seq_num 
    FROM ledger_entries 
    WHERE posting_date = p_date AND voucher_no LIKE 'EXP-%';
    
    v_voucher_no := 'EXP-' || TO_CHAR(p_date, 'YYYYMMDD') || '-' || LPAD(v_seq_num::TEXT, 3, '0');

    -- 3. Double-Entry Posting
    -- DEBIT: Expense Account (Increases Expense)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'payment', p_date, p_expense_account_id, p_amount, 0, p_narration, auth.uid());

    -- CREDIT: Asset Account (Decreases Cash/Bank)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'payment', p_date, p_payment_account_id, 0, p_amount, p_narration, auth.uid());

    SELECT json_build_object('success', true, 'voucher_no', v_voucher_no) INTO v_result;
    RETURN v_result;
END;
$$;

COMMIT;

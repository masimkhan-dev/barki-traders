-- =================================================================
-- SENIOR ARCHITECT FIX: OPENING BALANCE & BANK ACCOUNT SYSTEM
-- Version: 2.0 (Audit-Grade)
-- Date: 2026-01-30
-- Targets: Correct Account Codes, Robust RPC, Consistent Reporting
-- =================================================================

BEGIN;

-- 1. CLEANUP / PREPARE ACCOUNTS (Non-Destructive)
-- We ensure Cash, Bank, and Capital accounts are correctly configured.

DO $$
DECLARE 
    v_asset_root UUID;
    v_equity_root UUID;
BEGIN
    -- Find Root IDs
    SELECT id INTO v_asset_root FROM public.accounts WHERE code = '1000' OR slug = 'assets_root';
    SELECT id INTO v_equity_root FROM public.accounts WHERE code = '5000' OR slug = 'equity_root';

    -- [A] Ensure Cash Account is correctly coded to 1010
    UPDATE public.accounts 
    SET code = '1010', name = 'Cash on Hand', slug = 'cash', account_type = 'asset'
    WHERE slug = 'cash' OR code = '1010';

    -- [B] Ensure Bank Account exists (Code 1020)
    INSERT INTO public.accounts (code, name, account_type, slug, parent_id, is_system, is_active)
    VALUES ('1020', 'Bank Account', 'asset', 'bank', v_asset_root, true, true)
    ON CONFLICT (code) DO UPDATE SET name = 'Bank Account', slug = 'bank', is_active = true;

    -- [C] Ensure Opening Capital Account exists (Code 5100)
    INSERT INTO public.accounts (code, name, account_type, slug, parent_id, is_system, is_active)
    VALUES ('5100', 'Initial Opening Balance', 'equity', 'opening_capital', v_equity_root, true, true)
    ON CONFLICT (code) DO UPDATE SET name = 'Initial Opening Balance', slug = 'opening_capital', is_active = true;

    -- [D] Fix potential '3000' code conflict (If it was erroneously marked as Income root)
    UPDATE public.accounts SET name = 'Income Root', account_type = 'income' WHERE code = '3000' AND slug = 'income_root';
END $$;

-- 2. REWRITE: setup_opening_balances (Robust Version)
-- This function handles the double-entry for starting the system.

CREATE OR REPLACE FUNCTION public.setup_opening_balances(
    p_cash_amount NUMERIC,
    p_bank_amount NUMERIC,
    p_opening_date DATE
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_cash_id UUID;
    v_bank_id UUID;
    v_equity_id UUID;
    v_voucher_no TEXT;
    v_user_id UUID;
BEGIN
    -- [1] Basic Validations
    IF p_cash_amount < 0 OR p_bank_amount < 0 THEN
        RAISE EXCEPTION 'Opening balances cannot be negative';
    END IF;

    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    -- [2] Identify Target Accounts
    SELECT id INTO v_cash_id FROM public.accounts WHERE code = '1010' AND account_type = 'asset' LIMIT 1;
    SELECT id INTO v_bank_id FROM public.accounts WHERE code = '1020' AND account_type = 'asset' LIMIT 1;
    SELECT id INTO v_equity_id FROM public.accounts WHERE code = '5100' AND account_type = 'equity' LIMIT 1;

    IF v_cash_id IS NULL OR v_bank_id IS NULL OR v_equity_id IS NULL THEN
        RAISE EXCEPTION 'Critical Chart of Accounts codes missing (1010, 1020, or 5100)';
    END IF;

    -- [3] Check for Duplicates (Prevent multiple opening records)
    -- We use a standardized voucher format OPEN-YYYYMMDD-INIT
    v_voucher_no := 'OPEN-' || to_char(p_opening_date, 'YYYYMMDD') || '-INIT';

    IF EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = v_voucher_no) THEN
        RAISE EXCEPTION 'Opening balances for this date already exist (Voucher: %)', v_voucher_no;
    END IF;

    -- [4] Post Double-Entry (Transactional)
    
    -- CASH OPENING
    IF p_cash_amount > 0 THEN
        -- DB: Cash
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by, quantity, rate)
        VALUES (v_voucher_no, 'opening', p_opening_date, v_cash_id, p_cash_amount, 0, 'Opening Balance - Cash', v_user_id, 0, 0);
        
        -- CR: Equity
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by, quantity, rate)
        VALUES (v_voucher_no, 'opening', p_opening_date, v_equity_id, 0, p_cash_amount, 'Opening Balance - Cash Offset', v_user_id, 0, 0);
    END IF;

    -- BANK OPENING
    IF p_bank_amount > 0 THEN
        -- DB: Bank
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by, quantity, rate)
        VALUES (v_voucher_no, 'opening', p_opening_date, v_bank_id, p_bank_amount, 0, 'Opening Balance - Bank', v_user_id, 0, 0);
        
        -- CR: Equity
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by, quantity, rate)
        VALUES (v_voucher_no, 'opening', p_opening_date, v_equity_id, 0, p_bank_amount, 'Opening Balance - Bank Offset', v_user_id, 0, 0);
    END IF;

    RETURN json_build_object(
        'success', true,
        'voucher_no', v_voucher_no,
        'message', 'Initial opening balances posted successfully'
    );
END;
$$;

-- 3. ENSURE REPORT INTEGRITY
-- Since we use account_type 'equity' for the offset and 'asset' for Cash/Bank, 
-- existing reports like Profit & Loss will naturally IGNORE these entries 
-- (because they only look at income/expense), while Balance Sheet will pick them up flawlessly.

COMMIT;

-- VERIFICATION QUERY
-- SELECT * FROM accounts WHERE code IN ('1010', '1020', '5100');

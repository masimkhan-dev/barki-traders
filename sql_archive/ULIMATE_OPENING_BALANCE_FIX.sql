-- =================================================================
-- SENIOR ARCHITECT FIX: FINAL GOLD-STANDARD OPENING BALANCES
-- Version: 4.0 (The "Bulletproof" Edition)
-- Date: 2026-01-30
-- Targets: Solves Future-Date Locks, Fragmented Equity, and Uniqueness
-- =================================================================

BEGIN;

-- 1. REWRITE: setup_opening_balances (Final Refined Version)
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
    v_total_amount NUMERIC;
BEGIN
    -- [GUARD 1] Basic Validations
    p_cash_amount := COALESCE(p_cash_amount, 0);
    p_bank_amount := COALESCE(p_bank_amount, 0);
    v_total_amount := p_cash_amount + p_bank_amount;

    IF p_cash_amount < 0 OR p_bank_amount < 0 THEN
        RAISE EXCEPTION 'Opening balances cannot be negative';
    END IF;

    IF v_total_amount <= 0 THEN
        RAISE EXCEPTION 'Total opening balance must be greater than zero';
    END IF;

    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    -- [GUARD 2] Global One-Time Lock
    -- Ensures opening is only set once per system lifetime
    IF EXISTS (
        SELECT 1 FROM public.ledger_entries 
        WHERE voucher_type = 'opening'
    ) THEN
        RAISE EXCEPTION 'Opening balances have already been established and cannot be modified.';
    END IF;

    -- [GUARD 3] Historical Sequence Integrity
    -- Relaxed: Only blocks if transactions exist BEFORE the opening date.
    -- This allows fixing future-dated mistakes while ensuring the "Start" is truly the "Start".
    IF EXISTS (
        SELECT 1 FROM public.ledger_entries 
        WHERE posting_date < p_opening_date
    ) THEN
        RAISE EXCEPTION 'Integrity Error: Transactions already exist before the selected opening date (%). Opening balance must be the earliest record.', p_opening_date;
    END IF;

    -- [GUARD 4] Robust Lookup (Slug + Type)
    SELECT id INTO v_cash_id FROM public.accounts WHERE (slug = 'cash' OR code = '1010') AND account_type = 'asset' LIMIT 1;
    SELECT id INTO v_bank_id FROM public.accounts WHERE (slug = 'bank' OR code = '1020') AND account_type = 'asset' LIMIT 1;
    SELECT id INTO v_equity_id FROM public.accounts WHERE (slug = 'opening_capital' OR code = '5100') AND account_type = 'equity' LIMIT 1;

    IF v_cash_id IS NULL OR v_bank_id IS NULL OR v_equity_id IS NULL THEN
        RAISE EXCEPTION 'Configuration Error: Critical accounts (Cash, Bank, or Equity Offset) not found in Chart of Accounts.';
    END IF;

    -- [5] Unique Voucher Generation
    -- Added Random suffix to ensure uniqueness even in race conditions or retries
    v_voucher_no := 'OPEN-' || to_char(p_opening_date, 'YYYYMMDD') || '-INIT-' || upper(substring(replace(gen_random_uuid()::text, '-', ''), 1, 4));

    -- [6] Transactional Postings (Atomic & Clean)
    
    -- DEBIT: Cash (If applicable)
    IF p_cash_amount > 0 THEN
        INSERT INTO public.ledger_entries (
            voucher_no, voucher_type, posting_date, account_id, 
            debit_amount, credit_amount, 
            narration, created_by, quantity, rate
        )
        VALUES (v_voucher_no, 'opening', p_opening_date, v_cash_id, p_cash_amount, 0, 'Initial System Setup: Cash on Hand', v_user_id, 0, 0);
    END IF;

    -- DEBIT: Bank (If applicable)
    IF p_bank_amount > 0 THEN
        INSERT INTO public.ledger_entries (
            voucher_no, voucher_type, posting_date, account_id, 
            debit_amount, credit_amount, 
            narration, created_by, quantity, rate
        )
        VALUES (v_voucher_no, 'opening', p_opening_date, v_bank_id, p_bank_amount, 0, 'Initial System Setup: Bank Balance', v_user_id, 0, 0);
    END IF;

    -- CREDIT: Combined Equity (Aggregated for Reporting Clarity)
    -- One single credit row for all assets being initialized
    INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, 
        debit_amount, credit_amount, 
        narration, created_by, quantity, rate
    )
    VALUES (v_voucher_no, 'opening', p_opening_date, v_equity_id, 0, v_total_amount, 'Initial System Setup: Capital Offset', v_user_id, 0, 0);

    -- [7] Audit Metadata Response
    RETURN json_build_object(
        'success', true,
        'voucher_no', v_voucher_no,
        'details', json_build_object(
            'cash', p_cash_amount,
            'bank', p_bank_amount,
            'total_equity', v_total_amount
        )
    );
END;
$$;

COMMIT;

-- =================================================================
-- SENIOR ARCHITECT FIX: PRODUCTION-GRADE OPENING BALANCES
-- Version: 3.0 (Operational Safety + Audit Guards)
-- Date: 2026-01-30
-- Targets: Slug-based lookup, One-time lock, Historical Integrity
-- =================================================================

BEGIN;

-- 1. REWRITE: setup_opening_balances (Hardened Production Version)
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
    v_meta JSON;
BEGIN
    -- [GUARD 1] Basic Validations
    IF p_cash_amount < 0 OR p_bank_amount < 0 THEN
        RAISE EXCEPTION 'Opening balances cannot be negative';
    END IF;

    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    -- [GUARD 2] Global Lock - Prevent multiple runs of opening balance
    IF EXISTS (
        SELECT 1 FROM public.ledger_entries 
        WHERE voucher_type = 'opening'
    ) THEN
        RAISE EXCEPTION 'Opening balances have already been configured for this system';
    END IF;

    -- [GUARD 3] Historical Integrity - No opening balance after transactions exist
    IF EXISTS (
        SELECT 1 FROM public.ledger_entries 
        WHERE posting_date >= p_opening_date
    ) THEN
        RAISE EXCEPTION 'Cannot set opening balance: Transactions already exist on or after the selected date (%)', p_opening_date;
    END IF;

    -- [GUARD 4] Robust Lookup (Slug + Type)
    SELECT id INTO v_cash_id FROM public.accounts WHERE (slug = 'cash' OR code = '1010') AND account_type = 'asset' LIMIT 1;
    SELECT id INTO v_bank_id FROM public.accounts WHERE (slug = 'bank' OR code = '1020') AND account_type = 'asset' LIMIT 1;
    SELECT id INTO v_equity_id FROM public.accounts WHERE (slug = 'opening_capital' OR code = '5100') AND account_type = 'equity' LIMIT 1;

    IF v_cash_id IS NULL OR v_bank_id IS NULL OR v_equity_id IS NULL THEN
        RAISE EXCEPTION 'Critical Chart of Accounts components missing (Slugs: cash, bank, or opening_capital)';
    END IF;

    -- [5] Final Voucher No Construction
    v_voucher_no := 'OPEN-' || to_char(p_opening_date, 'YYYYMMDD') || '-INIT';

    -- [6] Transactional Postings (Atomic)
    
    -- CASH POSTING
    IF p_cash_amount > 0 THEN
        INSERT INTO public.ledger_entries (
            voucher_no, voucher_type, posting_date, account_id, 
            debit_amount, credit_amount, 
            narration, created_by, quantity, rate
        )
        VALUES (v_voucher_no, 'opening', p_opening_date, v_cash_id, p_cash_amount, 0, 'Opening Balance (System Initialized — No Qty)', v_user_id, 0, 0);
        
        INSERT INTO public.ledger_entries (
            voucher_no, voucher_type, posting_date, account_id, 
            debit_amount, credit_amount, 
            narration, created_by, quantity, rate
        )
        VALUES (v_voucher_no, 'opening', p_opening_date, v_equity_id, 0, p_cash_amount, 'Opening Balance Offset (Equity)', v_user_id, 0, 0);
    END IF;

    -- BANK POSTING
    IF p_bank_amount > 0 THEN
        INSERT INTO public.ledger_entries (
            voucher_no, voucher_type, posting_date, account_id, 
            debit_amount, credit_amount, 
            narration, created_by, quantity, rate
        )
        VALUES (v_voucher_no, 'opening', p_opening_date, v_bank_id, p_bank_amount, 0, 'Opening Balance (System Initialized — No Qty)', v_user_id, 0, 0);
        
        INSERT INTO public.ledger_entries (
            voucher_no, voucher_type, posting_date, account_id, 
            debit_amount, credit_amount, 
            narration, created_by, quantity, rate
        )
        VALUES (v_voucher_no, 'opening', p_opening_date, v_equity_id, 0, p_bank_amount, 'Opening Balance Offset (Equity)', v_user_id, 0, 0);
    END IF;

    -- [7] Structured Response for UX
    v_meta := json_build_object(
        'success', true,
        'voucher_no', v_voucher_no,
        'cash_posted', p_cash_amount > 0,
        'bank_posted', p_bank_amount > 0,
        'total_impact', p_cash_amount + p_bank_amount
    );

    RETURN v_meta;
END;
$$;

COMMIT;

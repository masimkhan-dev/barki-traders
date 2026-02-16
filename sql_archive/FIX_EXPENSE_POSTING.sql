-- =================================================================
-- EXPENSE POSTING ENGINE FIX (Jan 30, 2026)
-- Target: Fix 400 Error and Sync with Production Standards
-- =================================================================

BEGIN;

-- 1. DROP old function to avoid parameter mismatch errors
DROP FUNCTION IF EXISTS public.post_expense_entry(UUID, UUID, NUMERIC, TEXT, DATE);

-- 2. CREATE robust version
CREATE OR REPLACE FUNCTION public.post_expense_entry(
    p_expense_account_id UUID,
    p_payment_account_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE
) RETURNS json 
LANGUAGE plpgsql 
SECURITY DEFINER 
AS $$
DECLARE
    v_voucher_no TEXT;
    v_seq_num BIGINT;
    v_result json;
    v_date_str TEXT;
BEGIN
    -- [A] VALIDATIONS
    IF p_amount <= 0 THEN 
        RAISE EXCEPTION 'Amount must be positive. Received: %', p_amount; 
    END IF;
    
    -- Ensure target is actually an Expense account
    IF NOT EXISTS (SELECT 1 FROM public.accounts WHERE id = p_expense_account_id AND account_type = 'expense') THEN
        RAISE EXCEPTION 'Target account is not an Expense type.';
    END IF;

    -- [B] VOUCHER GENERATION (Use Standard Sequence)
    -- Using the same sequence as other payments for consistency
    v_date_str := to_char(COALESCE(p_date, CURRENT_DATE), 'YYYYMMDD');
    SELECT nextval('voucher_seq_payment_v2') INTO v_seq_num;
    v_voucher_no := 'EXP-' || v_date_str || '-' || lpad(v_seq_num::text, 4, '0');

    -- [C] DOUBLE-ENTRY POSTING
    -- 1. DEBIT: Expense Account (Increases Expense)
    INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, 
        debit_amount, credit_amount, narration, created_by,
        quantity, rate
    )
    VALUES (
        v_voucher_no, 'payment', p_date, p_expense_account_id, 
        p_amount, 0, p_narration, auth.uid(),
        0, 0
    );

    -- 2. CREDIT: Asset Account (Decreases Cash/Bank)
    INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, 
        debit_amount, credit_amount, narration, created_by,
        quantity, rate
    )
    VALUES (
        v_voucher_no, 'payment', p_date, p_payment_account_id, 
        0, p_amount, p_narration, auth.uid(),
        0, 0
    );

    -- [D] RETURN RESULT
    SELECT json_build_object(
        'success', true, 
        'voucher_no', v_voucher_no,
        'message', 'Expense posted successfully'
    ) INTO v_result;
    
    RETURN v_result;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'EXPENSE_POST_ERROR: %', SQLERRM;
END;
$$;

COMMIT;

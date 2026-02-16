-- =================================================================
-- OWNER WITHDRAWAL / DRAWINGS FEATURE
--
-- WHAT THIS DOES:
--   1. Creates "Owner's Drawings" account (equity, code 3200)
--   2. Creates RPC: post_owner_withdrawal
--      → Dr: Owner's Drawings (equity decreases)
--      → Cr: Cash / Bank (asset decreases)
--
-- RUN THIS IN SUPABASE SQL EDITOR
-- =================================================================

BEGIN;

-- =================================================================
-- STEP 1: Create Owner's Drawings Account
-- =================================================================
INSERT INTO public.accounts (name, slug, code, account_type, is_system, is_active)
VALUES ('Owner''s Drawings', 'owner_drawings', '3200', 'equity', true, true)
ON CONFLICT (slug) DO NOTHING;

-- Verify
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.accounts WHERE slug = 'owner_drawings') THEN
        RAISE EXCEPTION 'Failed to create Owner''s Drawings account!';
    END IF;
    RAISE NOTICE '✅ Owner''s Drawings account ready (code 3200)';
END $$;


-- =================================================================
-- STEP 2: Create RPC for Owner Withdrawal
-- =================================================================
CREATE OR REPLACE FUNCTION public.post_owner_withdrawal(
    p_payment_account_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_voucher_no TEXT;
    v_drawings_id UUID;
    v_seq_num INT;
BEGIN
    -- Validate amount
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive. Got: %', p_amount;
    END IF;

    -- Validate payment source
    IF p_payment_account_id IS NULL THEN
        RAISE EXCEPTION 'Payment source account is required';
    END IF;

    -- Get Owner's Drawings account
    SELECT id INTO v_drawings_id FROM public.accounts WHERE slug = 'owner_drawings';
    IF v_drawings_id IS NULL THEN
        RAISE EXCEPTION 'Owner''s Drawings account not found. Run setup first.';
    END IF;

    -- Generate voucher number: DRW-YYYYMMDD-001
    SELECT COALESCE(COUNT(*), 0) + 1 INTO v_seq_num
    FROM ledger_entries
    WHERE posting_date = p_date AND voucher_no LIKE 'DRW-%';

    v_voucher_no := 'DRW-' || TO_CHAR(p_date, 'YYYYMMDD') || '-' || LPAD(v_seq_num::TEXT, 3, '0');

    -- Post double-entry:
    --   Dr: Owner's Drawings (equity reduces)
    --   Cr: Cash/Bank (asset reduces)
    INSERT INTO ledger_entries (
        voucher_no, voucher_type, posting_date,
        account_id, debit_amount, credit_amount,
        narration, created_by
    ) VALUES
        (v_voucher_no, 'payment', p_date, v_drawings_id,
         p_amount, 0, COALESCE(p_narration, 'Owner Withdrawal'), auth.uid()),
        (v_voucher_no, 'payment', p_date, p_payment_account_id,
         0, p_amount, COALESCE(p_narration, 'Owner Withdrawal'), auth.uid());

    RETURN json_build_object(
        'success', true,
        'voucher_no', v_voucher_no,
        'amount', p_amount
    );
END; $$;


-- =================================================================
-- STEP 3: Verify
-- =================================================================
SELECT proname, pronargs
FROM pg_proc
WHERE proname = 'post_owner_withdrawal'
  AND pronamespace = 'public'::regnamespace;

COMMIT;

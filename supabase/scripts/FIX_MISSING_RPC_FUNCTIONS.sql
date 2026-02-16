-- =================================================================
-- 🚑 MISSING RPC FIX: Functions called by frontend but NOT in database
-- 
-- ERROR: "Could not find function public.post_munshi_voucher"
-- CAUSE: Baseline V11 dropped all functions but didn't recreate these 3:
--   1. post_munshi_voucher (ManageTransactions.tsx → Tab 1: Transfers)
--   2. post_expense_entry  (Expenses.tsx → Standard expenses)
--   3. purchase_fixed_asset (Expenses.tsx → Asset purchases)
--
-- RUN THIS IN SUPABASE SQL EDITOR IMMEDIATELY.
-- =================================================================

BEGIN;

SET search_path = public;

-- =================================================================
-- 1. POST_MUNSHI_VOUCHER (Transfer / Online Payment / Voucher)
-- Called from: ManageTransactions.tsx line 276
-- Parameters match exactly what frontend sends
-- =================================================================

-- Drop any old signature versions first
DROP FUNCTION IF EXISTS public.post_munshi_voucher(uuid,uuid,numeric,text,date);
DROP FUNCTION IF EXISTS public.post_munshi_voucher(uuid,uuid,numeric,text,date,text);

CREATE OR REPLACE FUNCTION public.post_munshi_voucher(
    p_from_account_id UUID,
    p_to_account_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE,
    p_voucher_no TEXT DEFAULT NULL
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_voucher_no TEXT;
    v_dr_acct UUID; v_cr_acct UUID;
    v_from_is_party BOOLEAN; v_to_is_party BOOLEAN;
    v_party_type TEXT;
    v_ar_id UUID; v_ap_id UUID;
BEGIN
    -- Validate amount
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive. Got: %', p_amount;
    END IF;

    -- Lookup control accounts
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';

    -- EDIT MODE: If voucher_no provided, scrub old entries first
    IF p_voucher_no IS NOT NULL THEN
        v_voucher_no := p_voucher_no;
        DELETE FROM public.ledger_entries WHERE voucher_no = v_voucher_no;
        -- Clean from payments table too if it exists there
        BEGIN
            DELETE FROM public.payments WHERE voucher_no = v_voucher_no;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    ELSE
        -- NEW MODE: Generate unique voucher number
        v_voucher_no := 'VCH-' || TO_CHAR(p_date, 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 9999)::TEXT, 4, '0');
    END IF;

    -- Resolve FROM (Giver/Source): Could be account or party
    SELECT EXISTS(SELECT 1 FROM parties WHERE id = p_from_account_id) INTO v_from_is_party;
    IF v_from_is_party THEN
        SELECT type INTO v_party_type FROM parties WHERE id = p_from_account_id;
        v_cr_acct := CASE WHEN v_party_type = 'supplier' THEN v_ap_id ELSE v_ar_id END;
    ELSE
        v_cr_acct := p_from_account_id;
    END IF;

    -- Resolve TO (Receiver/Destination): Could be account or party
    SELECT EXISTS(SELECT 1 FROM parties WHERE id = p_to_account_id) INTO v_to_is_party;
    IF v_to_is_party THEN
        SELECT type INTO v_party_type FROM parties WHERE id = p_to_account_id;
        v_dr_acct := CASE WHEN v_party_type = 'supplier' THEN v_ap_id ELSE v_ar_id END;
    ELSE
        v_dr_acct := p_to_account_id;
    END IF;

    -- Post double-entry: Debit receiver, Credit giver
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES
        (v_voucher_no, 'transfer', p_date, v_dr_acct,
         CASE WHEN v_to_is_party THEN p_to_account_id ELSE NULL END,
         p_amount, 0, p_narration, auth.uid()),
        (v_voucher_no, 'transfer', p_date, v_cr_acct,
         CASE WHEN v_from_is_party THEN p_from_account_id ELSE NULL END,
         0, p_amount, p_narration, auth.uid());

    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END; $$;


-- =================================================================
-- 2. POST_EXPENSE_ENTRY (Standard Expense Recording)
-- Called from: Expenses.tsx line 144
-- =================================================================

DROP FUNCTION IF EXISTS public.post_expense_entry(uuid,uuid,numeric,text,date);
DROP FUNCTION IF EXISTS public.post_expense_entry(uuid,uuid,numeric,text,date,text);

CREATE OR REPLACE FUNCTION public.post_expense_entry(
    p_expense_account_id UUID,
    p_payment_account_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE,
    p_voucher_no TEXT DEFAULT NULL
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_voucher_no TEXT;
    v_seq_num INT;
BEGIN
    -- Validate amount
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive. Got: %', p_amount;
    END IF;

    -- EDIT MODE: Scrub old entries
    IF p_voucher_no IS NOT NULL THEN
        v_voucher_no := p_voucher_no;
        DELETE FROM public.ledger_entries WHERE voucher_no = v_voucher_no;
    ELSE
        -- NEW MODE: Generate EXP-YYYYMMDD-001 format
        SELECT COALESCE(COUNT(*), 0) + 1 INTO v_seq_num
        FROM ledger_entries
        WHERE posting_date = p_date AND voucher_no LIKE 'EXP-%';
        v_voucher_no := 'EXP-' || TO_CHAR(p_date, 'YYYYMMDD') || '-' || LPAD(v_seq_num::TEXT, 3, '0');
    END IF;

    -- Post double-entry: Debit expense, Credit payment source
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES
        (v_voucher_no, 'payment', p_date, p_expense_account_id, p_amount, 0, p_narration, auth.uid()),
        (v_voucher_no, 'payment', p_date, p_payment_account_id, 0, p_amount, p_narration, auth.uid());

    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END; $$;


-- =================================================================
-- 3. PURCHASE_FIXED_ASSET (Enterprise Asset Purchase)
-- Called from: Expenses.tsx line 129
-- Creates a new account for the asset + posts ledger entry
-- =================================================================

CREATE OR REPLACE FUNCTION public.purchase_fixed_asset(
    p_name TEXT,
    p_category TEXT,
    p_amount NUMERIC,
    p_date DATE,
    p_paid_from_account_id UUID,
    p_description TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_asset_account_id UUID;
    v_voucher_no TEXT;
    v_new_code TEXT;
    v_max_code INTEGER;
BEGIN
    -- Validate
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    IF p_paid_from_account_id IS NULL THEN RAISE EXCEPTION 'Payment source account is required'; END IF;

    -- Generate unique account code for the new asset
    BEGIN
        SELECT MAX(code::INTEGER) INTO v_max_code
        FROM public.accounts
        WHERE code ~ '^[0-9]+$';

        IF v_max_code IS NULL THEN
            v_max_code := 10000;
        END IF;

        v_new_code := (v_max_code + 1)::TEXT;
    EXCEPTION WHEN OTHERS THEN
        v_new_code := 'FA-' || to_char(now(), 'MMDDSS');
    END;

    -- Create the Fixed Asset Account
    INSERT INTO public.accounts (name, code, account_type, sub_category, is_active, is_system, created_at)
    VALUES (p_name, v_new_code, 'asset', p_category, true, false, NOW())
    RETURNING id INTO v_asset_account_id;

    -- Generate voucher number
    v_voucher_no := 'EXP-' || to_char(p_date, 'YYYYMMDD') || '-' || substring(md5(random()::text) from 1 for 4);

    -- Post double-entry: Debit Asset, Credit Cash/Bank
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES
        (v_voucher_no, 'payment', p_date, v_asset_account_id, p_amount, 0, p_description, auth.uid()),
        (v_voucher_no, 'payment', p_date, p_paid_from_account_id, 0, p_amount, p_description, auth.uid());

    RETURN jsonb_build_object('success', true, 'voucher_no', v_voucher_no, 'asset_account_id', v_asset_account_id);
END; $$;


-- =================================================================
-- 4. VERIFICATION
-- =================================================================

-- Verify all 3 functions exist
SELECT proname, pronargs
FROM pg_proc
WHERE proname IN ('post_munshi_voucher', 'post_expense_entry', 'purchase_fixed_asset')
  AND pronamespace = 'public'::regnamespace;

COMMIT;

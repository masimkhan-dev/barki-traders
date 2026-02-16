-- =================================================================
-- SMART ACCOUNTING REPAIR: KEEP VOUCHER NO AND SYNC BALANCES
-- =================================================================

BEGIN;

SET search_path = public;

-- Drop old functions to fix parameter names and add p_voucher_no
DROP FUNCTION IF EXISTS public.post_expense_entry(uuid,uuid,numeric,text,date);
DROP FUNCTION IF EXISTS public.post_munshi_voucher(uuid,uuid,numeric,text,date);

--------------------------------------------------------------------------------
-- 1. SMART EXPENSE RPC (Supports Edits)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_expense_entry(
    p_expense_account_id UUID,
    p_payment_account_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE,
    p_voucher_no TEXT DEFAULT NULL  -- Added for Smart Update
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_voucher_no TEXT;
    v_seq_num INT;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    
    -- Edit Mode: Agar voucher no diya hai toh purana saaf karo
    IF p_voucher_no IS NOT NULL THEN
        v_voucher_no := p_voucher_no;
        DELETE FROM public.ledger_entries WHERE voucher_no = v_voucher_no;
    ELSE
        -- New Mode: Naya voucher generate karo
        SELECT COALESCE(COUNT(*), 0) + 1 INTO v_seq_num 
        FROM ledger_entries 
        WHERE posting_date = p_date AND voucher_no LIKE 'EXP-%';
        v_voucher_no := 'EXP-' || TO_CHAR(p_date, 'YYYYMMDD') || '-' || LPAD(v_seq_num::TEXT, 3, '0');
    END IF;

    -- Updated Ledger Lines Insert
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'payment', p_date, p_expense_account_id, p_amount, 0, p_narration, auth.uid()),
           (v_voucher_no, 'payment', p_date, p_payment_account_id, 0, p_amount, p_narration, auth.uid());

    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END; $$;

--------------------------------------------------------------------------------
-- 2. SMART TRANSFER RPC (Supports Edits)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_munshi_voucher(
    p_from_account_id UUID, -- Matching frontend name
    p_to_account_id UUID,   -- Matching frontend name
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE,
    p_voucher_no TEXT DEFAULT NULL -- Added for Smart Update
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_voucher_no TEXT;
    v_dr_acct UUID; v_cr_acct UUID;
    v_from_is_party BOOLEAN; v_to_is_party BOOLEAN;
    v_party_type TEXT;
    v_ar_id UUID; v_ap_id UUID;
BEGIN
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';

    -- Edit Mode Logic
    IF p_voucher_no IS NOT NULL THEN
        v_voucher_no := p_voucher_no;
        DELETE FROM public.ledger_entries WHERE voucher_no = v_voucher_no;
        -- If it exists in payments table, clean it too (Optional if table exists)
        BEGIN DELETE FROM public.payments WHERE voucher_no = v_voucher_no; EXCEPTION WHEN OTHERS THEN END;
    ELSE
        v_voucher_no := 'VCH-' || TO_CHAR(p_date, 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 9999)::TEXT, 4, '0');
    END IF;

    -- Resolve Giver/Receiver
    SELECT EXISTS(SELECT 1 FROM parties WHERE id = p_from_account_id) INTO v_from_is_party;
    IF v_from_is_party THEN SELECT type INTO v_party_type FROM parties WHERE id = p_from_account_id; v_cr_acct := CASE WHEN v_party_type = 'supplier' THEN v_ap_id ELSE v_ar_id END; ELSE v_cr_acct := p_from_account_id; END IF;
    SELECT EXISTS(SELECT 1 FROM parties WHERE id = p_to_account_id) INTO v_to_is_party;
    IF v_to_is_party THEN SELECT type INTO v_party_type FROM parties WHERE id = p_to_account_id; v_dr_acct := CASE WHEN v_party_type = 'supplier' THEN v_ap_id ELSE v_ar_id END; ELSE v_dr_acct := p_to_account_id; END IF;

    -- Updated Ledger Lines Insert
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'transfer', p_date, v_dr_acct, CASE WHEN v_to_is_party THEN p_to_account_id ELSE NULL END, p_amount, 0, p_narration, auth.uid()),
           (v_voucher_no, 'transfer', p_date, v_cr_acct, CASE WHEN v_from_is_party THEN p_from_account_id ELSE NULL END, 0, p_amount, p_narration, auth.uid());

    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END; $$;

COMMIT;

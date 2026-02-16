-- PHASE 24: FINAL RPC HARDENING & CLEANUP
-- MISSION: ENSURE ALL ENTRY POINTS ARE CONCURRENCY-SAFE AND AUDIT-PROOF
-- ---------------------------------------------------------------------------

BEGIN;

-- 1. HARDEN POST_MUNSHI_VOUCHER
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_munshi_voucher(
    p_from_account_id UUID,
    p_to_account_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_voucher_no TEXT;
    v_debit_gl_id UUID;
    v_credit_gl_id UUID;
    v_from_is_party BOOLEAN;
    v_to_is_party BOOLEAN;
    v_party_type TEXT;
    v_receivable_id UUID;
    v_payable_id UUID;
    v_result json;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    
    -- Generate Strict Voucher
    v_voucher_no := get_next_voucher_no('VCH', p_date);
    
    -- Lock Entities
    PERFORM 1 FROM parties WHERE id IN (p_from_account_id, p_to_account_id) FOR UPDATE;
    PERFORM 1 FROM accounts WHERE id IN (p_from_account_id, p_to_account_id) FOR UPDATE;

    -- Get control accounts
    SELECT id INTO v_receivable_id FROM accounts WHERE code = '1100';
    SELECT id INTO v_payable_id FROM accounts WHERE code = '2000';

    -- Resolve FROM account
    SELECT EXISTS(SELECT 1 FROM parties WHERE id = p_from_account_id) INTO v_from_is_party;
    IF v_from_is_party THEN
        SELECT type INTO v_party_type FROM parties WHERE id = p_from_account_id;
        v_credit_gl_id := CASE WHEN v_party_type = 'supplier' THEN v_payable_id ELSE v_receivable_id END;
    ELSE
        v_credit_gl_id := p_from_account_id;
    END IF;

    -- Resolve TO account
    SELECT EXISTS(SELECT 1 FROM parties WHERE id = p_to_account_id) INTO v_to_is_party;
    IF v_to_is_party THEN
        SELECT type INTO v_party_type FROM parties WHERE id = p_to_account_id;
        v_debit_gl_id := CASE WHEN v_party_type = 'supplier' THEN v_payable_id ELSE v_receivable_id END;
    ELSE
        v_debit_gl_id := p_to_account_id;
    END IF;

    -- Insert Ledger Entries
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES 
    (v_voucher_no, 'munshi_voucher', p_date, v_debit_gl_id, CASE WHEN v_to_is_party THEN p_to_account_id ELSE NULL END, p_amount, 0, p_narration, auth.uid()),
    (v_voucher_no, 'munshi_voucher', p_date, v_credit_gl_id, CASE WHEN v_from_is_party THEN p_from_account_id ELSE NULL END, 0, p_amount, p_narration, auth.uid());

    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END;
$$;


-- 2. HARDEN REVERSE_TRANSACTION
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reverse_transaction(
    p_voucher_no TEXT,
    p_reason TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_new_voucher_no TEXT;
    v_record_found BOOLEAN := false;
BEGIN
    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN RAISE EXCEPTION 'Reversal reason is mandatory'; END IF;
    IF p_voucher_no LIKE 'REV-%' THEN RAISE EXCEPTION 'Cannot reverse a reversal transaction'; END IF;

    -- Lock Ledger Entries for the voucher
    PERFORM 1 FROM ledger_entries WHERE voucher_no = p_voucher_no FOR UPDATE;

    IF EXISTS (SELECT 1 FROM ledger_entries WHERE voucher_no = p_voucher_no AND is_reversed = true) THEN
        RAISE EXCEPTION 'This transaction is already reversed';
    END IF;

    v_new_voucher_no := 'REV-' || p_voucher_no;

    -- Reversal logic (Mirroring 20260124160000 but adding locks)
    -- Sales
    IF EXISTS (SELECT 1 FROM sales WHERE voucher_no = p_voucher_no) THEN
        PERFORM 1 FROM sales WHERE voucher_no = p_voucher_no FOR UPDATE;
        INSERT INTO sales (voucher_no, sale_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, is_credit, notes, created_by)
        SELECT v_new_voucher_no, CURRENT_DATE, party_id, fuel_type_id, -quantity, rate_per_unit, -total_amount, is_credit, 'Reversal: ' || p_reason, auth.uid()
        FROM sales WHERE voucher_no = p_voucher_no;
        UPDATE sales SET is_reversed = true WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- Purchases
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM purchases WHERE voucher_no = p_voucher_no) THEN
        PERFORM 1 FROM purchases WHERE voucher_no = p_voucher_no FOR UPDATE;
        INSERT INTO purchases (voucher_no, purchase_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, notes, created_by)
        SELECT v_new_voucher_no, CURRENT_DATE, party_id, fuel_type_id, -quantity, rate_per_unit, -total_amount, 'Reversal: ' || p_reason, auth.uid()
        FROM purchases WHERE voucher_no = p_voucher_no;
        UPDATE purchases SET is_reversed = true WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- Payments
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM payments WHERE voucher_no = p_voucher_no) THEN
        PERFORM 1 FROM payments WHERE voucher_no = p_voucher_no FOR UPDATE;
        INSERT INTO payments (voucher_no, payment_type, payment_date, party_id, amount, notes, created_by)
        SELECT v_new_voucher_no, payment_type, CURRENT_DATE, party_id, -amount, 'Reversal: ' || p_reason, auth.uid()
        FROM payments WHERE voucher_no = p_voucher_no;
        UPDATE payments SET is_reversed = true WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- Generic Ledger
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM ledger_entries WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        SELECT v_new_voucher_no, voucher_type, CURRENT_DATE, account_id, party_id, credit_amount, debit_amount, 'Reversal: ' || p_reason, auth.uid()
        FROM ledger_entries WHERE voucher_no = p_voucher_no AND is_reversed = false;
        v_record_found := true;
    END IF;

    IF NOT v_record_found THEN RAISE EXCEPTION 'Voucher numbered % not found', p_voucher_no; END IF;

    UPDATE ledger_entries SET is_reversed = true, narration = COALESCE(narration, '') || ' (REVERSED)' WHERE voucher_no = p_voucher_no;

    RETURN json_build_object('success', true, 'reversal_voucher', v_new_voucher_no);
END;
$$;

COMMIT;

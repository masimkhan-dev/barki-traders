-- Phase 15: ADUDIT-SAFE REVERSAL MECHANISM
-- -----------------------------------------------------------------
-- 1. Schema updates to track reversals across all transaction tables.
-- 2. Core RPC to perform atomic reversals with inventory restoration.

BEGIN;

--------------------------------------------------------------------------------
-- 1. SCHEMA UPDATES
--------------------------------------------------------------------------------
-- Add reversal tracking to transaction tables
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS is_reversed BOOLEAN DEFAULT false;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS reverse_reason TEXT;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS reversal_of_voucher TEXT;

ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS is_reversed BOOLEAN DEFAULT false;
ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS reverse_reason TEXT;
ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS reversal_of_voucher TEXT;

ALTER TABLE public.payments ADD COLUMN IF NOT EXISTS is_reversed BOOLEAN DEFAULT false;
ALTER TABLE public.payments ADD COLUMN IF NOT EXISTS reverse_reason TEXT;
ALTER TABLE public.payments ADD COLUMN IF NOT EXISTS reversal_of_voucher TEXT;

-- Add reason to ledger_entries for better audit
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS reverse_reason TEXT;

--------------------------------------------------------------------------------
-- 2. CONSOLIDATED REVERSAL RPC
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reverse_transaction(
    p_voucher_no TEXT,
    p_reason TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_voucher_type TEXT;
    v_new_voucher_no TEXT;
    v_result json;
    v_record_found BOOLEAN := false;
BEGIN
    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        RAISE EXCEPTION 'Reversal reason is mandatory';
    END IF;

    v_new_voucher_no := 'REV-' || p_voucher_no;

    -- 1. Check if already reversed
    IF EXISTS (SELECT 1 FROM ledger_entries WHERE voucher_no = p_voucher_no AND is_reversed = true) THEN
        RAISE EXCEPTION 'This transaction is already reversed';
    END IF;

    -- 2. Handle SALES Reversal
    IF EXISTS (SELECT 1 FROM sales WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO sales (voucher_no, sale_date, customer_id, fuel_type_id, quantity, rate_per_unit, total_amount, is_credit, notes, created_by, reversal_of_voucher)
        SELECT v_new_voucher_no, CURRENT_DATE, customer_id, fuel_type_id, -quantity, rate_per_unit, -total_amount, is_credit, 'Reversal: ' || p_reason, auth.uid(), p_voucher_no
        FROM sales WHERE voucher_no = p_voucher_no;
        
        UPDATE sales SET is_reversed = true, reverse_reason = p_reason WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- 3. Handle PURCHASES Reversal
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM purchases WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO purchases (voucher_no, purchase_date, supplier_id, fuel_type_id, quantity, rate_per_unit, total_amount, notes, created_by, reversal_of_voucher)
        SELECT v_new_voucher_no, CURRENT_DATE, supplier_id, fuel_type_id, -quantity, rate_per_unit, -total_amount, 'Reversal: ' || p_reason, auth.uid(), p_voucher_no
        FROM purchases WHERE voucher_no = p_voucher_no;
        
        UPDATE purchases SET is_reversed = true, reverse_reason = p_reason WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- 4. Handle PAYMENTS/RECEIPTS Reversal
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM payments WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO payments (voucher_no, payment_type, payment_date, party_type, party_id, amount, payment_method, bank_name, cheque_no, notes, created_by, reversal_of_voucher)
        SELECT v_new_voucher_no, payment_type, CURRENT_DATE, party_type, party_id, -amount, payment_method, bank_name, cheque_no, 'Reversal: ' || p_reason, auth.uid(), p_voucher_no
        FROM payments WHERE voucher_no = p_voucher_no;
        
        UPDATE payments SET is_reversed = true, reverse_reason = p_reason WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- 5. Handle Generic LEDGER entries (e.g. Expenses or Manual Vouchers)
    -- If it wasn't in the main txn tables but exists in ledger
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM ledger_entries WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by, reversal_of)
        SELECT v_new_voucher_no, voucher_type, CURRENT_DATE, account_id, party_id, credit_amount, debit_amount, 'Reversal: ' || p_reason, auth.uid(), id
        FROM ledger_entries WHERE voucher_no = p_voucher_no AND is_reversed = false;
        
        v_record_found := true;
    END IF;

    IF NOT v_record_found THEN
        RAISE EXCEPTION 'Voucher numbered % not found in any transaction record', p_voucher_no;
    END IF;

    -- Final Mark on Ledger
    UPDATE ledger_entries 
    SET is_reversed = true, reverse_reason = p_reason 
    WHERE voucher_no = p_voucher_no;

    SELECT json_build_object('success', true, 'reversal_voucher', v_new_voucher_no) INTO v_result;
    RETURN v_result;
END;
$$;

COMMIT;

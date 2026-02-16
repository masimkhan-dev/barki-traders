-- =================================================================
-- FIX REVERSAL SYSTEM & TRIGGER BYPASS (Jan 30, 2026)
-- Target: Resolve 400 Errors during transaction reversal
-- =================================================================

BEGIN;

-- 1. UPDATE IMMUTABILITY TRIGGERS TO ALLOW 'is_reversed' UPDATES
-- ---------------------------------------------------------------------------

-- 1.1 For Ledger Entries
CREATE OR REPLACE FUNCTION public.prevent_ledger_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Allow updating ONLY is_reversed or narration
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.is_reversed IS DISTINCT FROM OLD.is_reversed) OR (NEW.narration IS DISTINCT FROM OLD.narration) THEN
            -- Only allow if nothing else is changing
            IF (NEW.id = OLD.id AND NEW.voucher_no = OLD.voucher_no AND NEW.account_id = OLD.account_id AND 
                NEW.debit_amount = OLD.debit_amount AND NEW.credit_amount = OLD.credit_amount AND 
                NEW.posting_date = OLD.posting_date) THEN
                RETURN NEW;
            END IF;
        END IF;
        RAISE EXCEPTION 'Ledger entries are immutable. Only marking as reversed is allowed.';
    END IF;
    
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Ledger entries cannot be deleted. Use reversal entries for corrections.';
    END IF;
    RETURN NULL;
END;
$$;

-- 1.2 For Sub-Ledgers (Sales, Purchases, Payments)
CREATE OR REPLACE FUNCTION public.prevent_subledger_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        -- Allow marking as reversed
        IF (NEW.is_reversed IS DISTINCT FROM OLD.is_reversed) THEN
             IF (NEW.id = OLD.id AND NEW.voucher_no = OLD.voucher_no AND NEW.total_amount = OLD.total_amount) THEN
                RETURN NEW;
             END IF;
        END IF;
        RAISE EXCEPTION 'Sub-ledger records are immutable. Only marking as reversed is allowed.';
    END IF;
    
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Sub-ledger records cannot be deleted. To correct errors, create reversal entries.';
    END IF;
    RETURN NULL;
END;
$$;


-- 2. UPDATE LEDGER INTEGRITY WHITELIST
-- ---------------------------------------------------------------------------
-- Add 'munshi_voucher' and 'transfer' to the allowed types
CREATE OR REPLACE FUNCTION public.ensure_source_document_exists()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- [A] WHITELIST VALIDATION
    IF NEW.voucher_type NOT IN (
        'sale', 'purchase', 'receipt', 'payment', 
        'opening_balance', 'transfer', 'journal', 'munshi_voucher'
    ) THEN
        RAISE EXCEPTION 'INVALID VOUCHER TYPE: "%"', NEW.voucher_type;
    END IF;

    -- [B] SOURCE VALIDATION (Only for sub-ledger integrated types)
    -- Expenses/Journal/Munshi Vouchers are direct GL entries and have NULL party_id or are independent
    
    -- For Sales: Always need a source
    IF NEW.voucher_type = 'sale' THEN
        IF NOT EXISTS (SELECT 1 FROM public.sales WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 'Source missing for sale voucher %', NEW.voucher_no;
        END IF;
    END IF;

    -- For Purchases: Always need a source
    IF NEW.voucher_type = 'purchase' THEN
        IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 'Source missing for purchase voucher %', NEW.voucher_no;
        END IF;
    END IF;

    -- For Receipts/Payments: Only need source IF a Party is involved
    IF NEW.voucher_type IN ('receipt', 'payment') AND NEW.party_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.payments WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 'Source missing for payment/receipt voucher % (Party involved)', NEW.voucher_no;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

-- 3. HARDEN REVERSE_TRANSACTION RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reverse_transaction(
    p_voucher_no TEXT,
    p_reason TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_new_voucher_no TEXT;
    v_record_found BOOLEAN := false;
    v_user_id UUID;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN RAISE EXCEPTION 'Reversal reason is mandatory'; END IF;
    IF p_voucher_no LIKE 'REV-%' THEN RAISE EXCEPTION 'Cannot reverse a reversal transaction'; END IF;

    -- Lock Ledger Entries for the voucher
    PERFORM 1 FROM ledger_entries WHERE voucher_no = p_voucher_no FOR UPDATE;

    IF EXISTS (SELECT 1 FROM ledger_entries WHERE voucher_no = p_voucher_no AND is_reversed = true) THEN
        RAISE EXCEPTION 'This transaction is already reversed';
    END IF;

    v_new_voucher_no := 'REV-' || p_voucher_no;

    -- 1. Try to reverse via Sales
    IF EXISTS (SELECT 1 FROM sales WHERE voucher_no = p_voucher_no) THEN
        PERFORM 1 FROM sales WHERE voucher_no = p_voucher_no FOR UPDATE;
        INSERT INTO sales (voucher_no, sale_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, is_credit, notes, created_by)
        SELECT v_new_voucher_no, CURRENT_DATE, party_id, fuel_type_id, -quantity, rate_per_unit, -total_amount, is_credit, 'Reversal: ' || p_reason, v_user_id
        FROM sales WHERE voucher_no = p_voucher_no;
        UPDATE sales SET is_reversed = true WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- 2. Try to reverse via Purchases
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM purchases WHERE voucher_no = p_voucher_no) THEN
        PERFORM 1 FROM purchases WHERE voucher_no = p_voucher_no FOR UPDATE;
        INSERT INTO purchases (voucher_no, purchase_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, notes, created_by)
        SELECT v_new_voucher_no, CURRENT_DATE, party_id, fuel_type_id, -quantity, rate_per_unit, -total_amount, 'Reversal: ' || p_reason, v_user_id
        FROM purchases WHERE voucher_no = p_voucher_no;
        UPDATE purchases SET is_reversed = true WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- 3. Try to reverse via Payments
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM payments WHERE voucher_no = p_voucher_no) THEN
        PERFORM 1 FROM payments WHERE voucher_no = p_voucher_no FOR UPDATE;
        INSERT INTO payments (voucher_no, payment_type, payment_date, party_id, amount, notes, created_by)
        SELECT v_new_voucher_no, payment_type, CURRENT_DATE, party_id, -amount, 'Reversal: ' || p_reason, v_user_id
        FROM payments WHERE voucher_no = p_voucher_no;
        UPDATE payments SET is_reversed = true WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- 4. Generic Ledger Reversal (For Munshi Vouchers, Transfers, Expenses)
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM ledger_entries WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        SELECT v_new_voucher_no, voucher_type, CURRENT_DATE, account_id, party_id, credit_amount, debit_amount, 'Reversal: ' || p_reason, v_user_id
        FROM ledger_entries WHERE voucher_no = p_voucher_no AND (is_reversed = false OR is_reversed IS NULL);
        v_record_found := true;
    END IF;

    IF NOT v_record_found THEN RAISE EXCEPTION 'Voucher numbered % not found', p_voucher_no; END IF;

    -- Mark original ledger entries as reversed
    UPDATE ledger_entries 
    SET is_reversed = true, 
        narration = COALESCE(narration, '') || ' (REVERSED: ' || p_reason || ')' 
    WHERE voucher_no = p_voucher_no;

    RETURN json_build_object('success', true, 'reversal_voucher', v_new_voucher_no);
END;
$$;

COMMIT;

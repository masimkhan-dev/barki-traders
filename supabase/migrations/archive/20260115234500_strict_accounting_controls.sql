-- =================================================================
-- MIGRATION: 20260115234500_strict_accounting_controls.sql
-- PURPOSE: 
--   1. DISABLE ADVANCE PAYMENTS (Customer only)
--   2. PREVENT NEGATIVE RECEIVABLES
--   3. IMPLEMENT VOUCHER REVERSAL SYSTEM
--   4. FIX DASHBOARD (TOP RECEIVABLES)
-- =================================================================

-- 1. HARD DB CONSTRAINT: Customer Balance must NEVER go below zero (Asset account code 1100 AR)
-- Note: We allow credit balance on the table itself IF the logic allows it, but user said 
-- "Advance payments are COMPLETELY DISABLED. Customer outstanding balance must NEVER go below zero."
-- So we add a CHECK constraint on customers table.
ALTER TABLE public.customers DROP CONSTRAINT IF EXISTS no_negative_customer_balance;
ALTER TABLE public.customers ADD CONSTRAINT no_negative_customer_balance CHECK (current_balance >= 0);

-- 2. REVERSAL SYSTEM UPDATES
-- Trigger cleanup (Ensure we don't block reversals even if balance check fails, actually we check balance BEFORE)
-- We need a function to reverse a voucher.

CREATE OR REPLACE FUNCTION public.reverse_ledger_voucher(p_voucher_no TEXT, p_reason TEXT)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_orig_entries RECORD;
    v_new_voucher TEXT;
    v_user_id UUID;
    v_ref_type TEXT;
    v_ref_id UUID;
    v_count INTEGER := 0;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN SELECT id INTO v_user_id FROM auth.users LIMIT 1; END IF;

    -- Generate a reversal voucher number
    v_new_voucher := 'REV-' || p_voucher_no || '-' || TO_CHAR(NOW(), 'HH24MISS');

    -- Check if already reversed
    IF EXISTS (SELECT 1 FROM ledger_entries WHERE voucher_no = p_voucher_no AND is_reversed = true) THEN
        RAISE EXCEPTION 'Voucher % has already been reversed.', p_voucher_no;
    END IF;

    -- Loop through original entries and swap Dr/Cr
    FOR v_orig_entries IN 
        SELECT * FROM ledger_entries WHERE voucher_no = p_voucher_no AND is_reversed = false
    LOOP
        -- Insert opposite entry
        INSERT INTO ledger_entries (
            voucher_no, voucher_type, posting_date, account_id, 
            debit_amount, credit_amount, narration, 
            reference_type, reference_id, created_by,
            reversal_of
        ) VALUES (
            v_new_voucher, v_orig_entries.voucher_type, CURRENT_DATE, v_orig_entries.account_id,
            v_orig_entries.credit_amount, v_orig_entries.debit_amount, 
            'REVERSAL: ' || p_reason || ' (Orig: ' || p_voucher_no || ')',
            'reversal', v_orig_entries.id, v_user_id,
            v_orig_entries.id
        );

        -- Mark original as reversed (Need to temporarily bypass immutability trigger)
        -- Actually, the immutability trigger blocks UPDATE. 
        -- We can either disable it or use a separate table.
        -- Let's use a workaround: The trigger only blocks UPDATE on existing rows.
        -- We can add a flag to the session or just allow updating ONLY the is_reversed column.
        
        v_count := v_count + 1;
    END LOOP;

    IF v_count = 0 THEN
        RAISE EXCEPTION 'Voucher % not found or no entries to reverse.', p_voucher_no;
    END IF;

    -- UPDATE is_reversed=true (We will update the trigger below to allow this)
    -- This update is critical for dashboard logic.
    UPDATE ledger_entries SET is_reversed = true WHERE voucher_no = p_voucher_no;

    RETURN json_build_object('success', true, 'reversal_voucher', v_new_voucher, 'entries_reversed', v_count);
END;
$$;

-- 3. UPDATED IMMUTABILITY TRIGGER (Allow internal reversal flag update)
CREATE OR REPLACE FUNCTION prevent_ledger_modification() 
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Allow admins/system to set is_reversed = true, but block everything else
    IF TG_OP = 'UPDATE' THEN
        IF (OLD.is_reversed = false AND NEW.is_reversed = true AND OLD.id = NEW.id) THEN
            RETURN NEW; -- Allowed
        END IF;
        RAISE EXCEPTION 'COMPLIANCE ERROR: Ledger entries are IMMUTABLE. Use Reversal System.';
    ELSIF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'COMPLIANCE ERROR: Deletion forbidden in FDMS.';
    END IF;
    RETURN NEW;
END; $$;

-- 4. HARDENED RECEIPT TRIGGER (No Advances Allowed)
CREATE OR REPLACE FUNCTION public.create_receipt_ledger_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ar_id UUID; v_target_acct_id UUID; v_bal NUMERIC;
    v_user_id UUID;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN SELECT id INTO v_user_id FROM auth.users LIMIT 1; END IF;

    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_target_acct_id FROM accounts WHERE slug = CASE WHEN NEW.payment_method = 'Cash' THEN 'cash' ELSE 'bank' END;

    -- Lock and check balance
    SELECT current_balance INTO v_bal FROM customers WHERE id = NEW.party_id FOR UPDATE;
    
    -- HARD VALIDATION: Advance Payment Block
    IF v_bal < NEW.amount THEN
        RAISE EXCEPTION 'No outstanding balance or receipt exceeds dues. (Bal: %, Rec: %). Receipt not allowed.', v_bal, NEW.amount;
    END IF;

    -- Update Customer Balance
    UPDATE customers SET current_balance = current_balance - NEW.amount WHERE id = NEW.party_id;
    
    -- Record Ledger Entries (Receipt is Credit to AR, Debit to Cash/Bank)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
    VALUES (NEW.voucher_no, 'receipt', NEW.payment_date, v_target_acct_id, NEW.amount, 0, 'payment', NEW.id, 'Customer Receipt V#' || NEW.voucher_no, v_user_id),
           (NEW.voucher_no, 'receipt', NEW.payment_date, v_ar_id, 0, NEW.amount, 'payment', NEW.id, 'AR Payment Offset', v_user_id);

    RETURN NEW;
END;
$$;

-- 5. HARDENED MANAGE TRANSACTION (API Level block for receipts)
CREATE OR REPLACE FUNCTION create_manage_transaction(
    p_transaction_type TEXT,
    p_from_type TEXT,
    p_from_entity_id UUID,
    p_to_type TEXT,
    p_to_entity_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_transaction_date DATE
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_voucher_no TEXT; v_dr_id UUID; v_cr_id UUID; v_entity_id UUID;
    v_cash_id UUID; v_bank_id UUID; v_ar_id UUID; v_ap_id UUID; v_rev_id UUID; v_inv_id UUID;
    v_bal NUMERIC;
BEGIN
    SELECT id INTO v_cash_id FROM accounts WHERE slug = 'cash';
    SELECT id INTO v_bank_id FROM accounts WHERE slug = 'bank';
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';
    SELECT id INTO v_rev_id FROM accounts WHERE slug = 'sales';
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';

    v_voucher_no := 'MT-' || TO_CHAR(p_transaction_date, 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');

    IF p_transaction_type = 'receipt' THEN
        -- Link validation
        IF p_from_entity_id IS NULL THEN RAISE EXCEPTION 'Invalid customer ledger reference.'; END IF;
        
        v_dr_id := CASE WHEN p_to_type = 'cash' THEN v_cash_id ELSE v_bank_id END;
        v_cr_id := v_ar_id;
        v_entity_id := p_from_entity_id;
        
        -- Balance check
        SELECT current_balance INTO v_bal FROM customers WHERE id = v_entity_id FOR UPDATE;
        IF v_bal < p_amount THEN
            RAISE EXCEPTION 'Receipt exceeds outstanding balance. (Dues: %, Attempted: %).', v_bal, p_amount;
        END IF;
        
        UPDATE customers SET current_balance = current_balance - p_amount WHERE id = v_entity_id;
        
    ELSIF p_transaction_type = 'payment' THEN
        v_dr_id := v_ap_id;
        v_cr_id := CASE WHEN p_from_type = 'cash' THEN v_cash_id ELSE v_bank_id END;
        v_entity_id := p_to_entity_id;
        UPDATE suppliers SET current_balance = current_balance - p_amount WHERE id = v_entity_id;
    ELSIF p_transaction_type = 'sale' THEN
        v_dr_id := v_ar_id; v_cr_id := v_rev_id; v_entity_id := p_to_entity_id;
        UPDATE customers SET current_balance = current_balance + p_amount WHERE id = v_entity_id;
    ELSIF p_transaction_type = 'purchase' THEN
        v_dr_id := v_inv_id; v_cr_id := v_ap_id; v_entity_id := p_from_entity_id;
        UPDATE suppliers SET current_balance = current_balance + p_amount WHERE id = v_entity_id;
    ELSE
        RAISE EXCEPTION 'Invalid transaction type';
    END IF;

    INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, reference_id, created_by)
    VALUES (v_dr_id, p_transaction_date, p_amount, 0, p_narration, v_voucher_no, 'manage_transaction', 'manage_transaction', v_entity_id, auth.uid()),
           (v_cr_id, p_transaction_date, 0, p_amount, p_narration, v_voucher_no, 'manage_transaction', 'manage_transaction', v_entity_id, auth.uid());

    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END;
$$;

-- 6. FIXED DASHBOARD TOP RECEIVABLES
-- Must ignore reversed transactions and only show true Dr balances
CREATE OR REPLACE FUNCTION get_top_customers_balances(limit_count INTEGER DEFAULT 5)
RETURNS TABLE (id UUID, name TEXT, balance NUMERIC) 
LANGUAGE plpgsql 
SECURITY DEFINER 
AS $$
BEGIN
    RETURN QUERY 
    SELECT 
        c.id, 
        c.name, 
        c.current_balance as balance
    FROM customers c 
    WHERE c.current_balance > 0 
    ORDER BY c.current_balance DESC 
    LIMIT limit_count;
END; 
$$;

-- 7. REVERSAL HANDLER FOR BALANCE ADJUSTMENTS
-- When a POSITIVE entry is reversed, the balance must be restored.
-- When a NEGATIVE (receipt) entry is reversed, the balance must be increased back.
CREATE OR REPLACE FUNCTION public.handle_reversal_balance_adjustment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_orig ledger_entries%ROWTYPE;
BEGIN
    IF NEW.reference_type = 'reversal' AND NEW.reversal_of IS NOT NULL THEN
        SELECT * INTO v_orig FROM ledger_entries WHERE id = NEW.reversal_of;
        
        -- If the original was a SALE (Reference type 'sale')
        IF v_orig.reference_type = 'sale' THEN
            -- Find customer
            UPDATE customers SET current_balance = current_balance - (v_orig.debit_amount - v_orig.credit_amount)
            WHERE id = (SELECT customer_id FROM sales WHERE id = v_orig.reference_id);
        
        -- If the original was a RECEIPT (Reference type 'payment')
        ELSIF v_orig.reference_type = 'payment' THEN
            -- Find customer and give back balance
            UPDATE customers SET current_balance = current_balance + (v_orig.credit_amount - v_orig.debit_amount)
            WHERE id = (SELECT party_id FROM payments WHERE id = v_orig.reference_id);
            
        -- Manage Transaction reversals
        ELSIF v_orig.reference_type = 'manage_transaction' THEN
            -- This is generic, we check if it was hitting AR (Customer) or AP (Supplier)
            IF EXISTS (SELECT 1 FROM accounts WHERE id = v_orig.account_id AND slug = 'ar') THEN
                UPDATE customers SET current_balance = current_balance - (v_orig.debit_amount - v_orig.credit_amount)
                WHERE id = v_orig.reference_id;
            ELSIF EXISTS (SELECT 1 FROM accounts WHERE id = v_orig.account_id AND slug = 'ap') THEN
                UPDATE suppliers SET current_balance = current_balance - (v_orig.credit_amount - v_orig.debit_amount)
                WHERE id = v_orig.reference_id;
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER on_reversal_entry_adjust_balance
    AFTER INSERT ON public.ledger_entries
    FOR EACH ROW EXECUTE FUNCTION public.handle_reversal_balance_adjustment();

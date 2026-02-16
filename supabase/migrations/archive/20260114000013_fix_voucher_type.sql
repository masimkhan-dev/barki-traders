-- =================================================================
-- MIGRATION: 20260114000013_fix_voucher_type.sql
-- PURPOSE: Fix missing voucher_type in INSERT statements
-- VERIFIER: Google DeepMind
-- =================================================================

CREATE OR REPLACE FUNCTION create_money_movement(
    p_from_type TEXT,
    p_from_party_id UUID,
    p_to_type TEXT,
    p_to_party_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_movement_date DATE
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_voucher TEXT;
    v_cust_bal NUMERIC;
    v_supp_bal NUMERIC;
    v_to_ar NUMERIC; 
    v_to_adv NUMERIC;
    v_dr_acct UUID;
    v_cr_acct UUID;
    v_dr_slug TEXT;
    v_cr_slug TEXT;
    -- Constant for voucher type
    c_v_type TEXT := 'money_movement'; 
BEGIN
    -- 1. Validation
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    
    -- 2. Voucher
    v_voucher := 'MM-' || TO_CHAR(p_movement_date, 'YYYYMMDD') || '-' || nextval('voucher_seq_mm')::TEXT;

    -- 3. CASE HANDLER
    
    -- CASE A: Customer PAYS (To Cash/Bank)
    IF p_from_type = 'customer' THEN
        -- LOCK CUSTOMER
        SELECT current_balance INTO v_cust_bal FROM customers WHERE id = p_from_party_id FOR UPDATE;
        
        -- UPDATE BALANCE (O(1))
        UPDATE customers SET current_balance = current_balance - p_amount WHERE id = p_from_party_id;
        
        -- SPLIT LOGIC
        IF v_cust_bal >= p_amount THEN
            v_to_ar := p_amount;
            v_to_adv := 0;
        ELSIF v_cust_bal > 0 THEN
            v_to_ar := v_cust_bal;
            v_to_adv := p_amount - v_cust_bal;
        ELSE
            v_to_ar := 0;
            v_to_adv := p_amount;
        END IF;
        
        -- TARGET ACCOUNT
        IF p_to_type = 'cash' THEN v_dr_slug := 'cash';
        ELSE v_dr_slug := 'bank'; END IF;
        SELECT id INTO v_dr_acct FROM accounts WHERE slug = v_dr_slug;
        
        -- WRITE LEDGER (AR)
        IF v_to_ar > 0 THEN
            SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'ar';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, reference_id)
            VALUES 
                (v_dr_acct, p_movement_date, v_to_ar, 0, p_narration, v_voucher, c_v_type, 'money_movement', p_from_party_id),
                (v_cr_acct, p_movement_date, 0, v_to_ar, p_narration, v_voucher, c_v_type, 'money_movement', p_from_party_id);
        END IF;
        
        -- WRITE LEDGER (Advance)
        IF v_to_adv > 0 THEN
            SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'customer_advance';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, reference_id)
            VALUES 
                (v_dr_acct, p_movement_date, v_to_adv, 0, p_narration || ' (Adv)', v_voucher, c_v_type, 'money_movement', p_from_party_id),
                (v_cr_acct, p_movement_date, 0, v_to_adv, p_narration || ' (Adv)', v_voucher, c_v_type, 'money_movement', p_from_party_id);
        END IF;

    -- CASE B: WE PAY Supplier (From Cash/Bank)
    ELSIF p_to_type = 'supplier' THEN
        -- LOCK SUPPLIER
        SELECT current_balance INTO v_supp_bal FROM suppliers WHERE id = p_to_party_id FOR UPDATE;
        
        -- UPDATE BALANCE (O(1))
        UPDATE suppliers SET current_balance = current_balance - p_amount WHERE id = p_to_party_id;
        
        -- SPLIT LOGIC
        IF v_supp_bal >= p_amount THEN
            v_to_ar := p_amount;
            v_to_adv := 0;
        ELSIF v_supp_bal > 0 THEN
            v_to_ar := v_supp_bal;
            v_to_adv := p_amount - v_supp_bal;
        ELSE
            v_to_ar := 0;
            v_to_adv := p_amount;
        END IF;
        
        -- SOURCE ACCOUNT
        IF p_from_type = 'cash' THEN v_cr_slug := 'cash';
        ELSE v_cr_slug := 'bank'; END IF;
        SELECT id INTO v_cr_acct FROM accounts WHERE slug = v_cr_slug;
        
        -- WRITE LEDGER (AP)
        IF v_to_ar > 0 THEN
            SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'ap';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, reference_id)
            VALUES 
                (v_dr_acct, p_movement_date, v_to_ar, 0, p_narration, v_voucher, c_v_type, 'money_movement', p_to_party_id),
                (v_cr_acct, p_movement_date, 0, v_to_ar, p_narration, v_voucher, c_v_type, 'money_movement', p_to_party_id);
        END IF;
        
        -- WRITE LEDGER (Advance)
        IF v_to_adv > 0 THEN
            SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'supplier_advance';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, reference_id)
            VALUES 
                (v_dr_acct, p_movement_date, v_to_adv, 0, p_narration || ' (Adv)', v_voucher, c_v_type, 'money_movement', p_to_party_id),
                (v_cr_acct, p_movement_date, 0, v_to_adv, p_narration || ' (Adv)', v_voucher, c_v_type, 'money_movement', p_to_party_id);
        END IF;

    -- CASE C: Internal Transfer
    ELSE
        -- Get IDs
        IF p_from_type = 'cash' THEN SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'cash';
        ELSIF p_from_type = 'bank' THEN SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'bank';
        ELSE RAISE EXCEPTION 'Invalid Source Type'; END IF;

        IF p_to_type = 'cash' THEN SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'cash';
        ELSIF p_to_type = 'bank' THEN SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'bank';
        ELSE RAISE EXCEPTION 'Invalid Dest Type'; END IF;

        INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type)
        VALUES 
            (v_dr_acct, p_movement_date, p_amount, 0, p_narration, v_voucher, c_v_type, 'money_movement'),
            (v_cr_acct, p_movement_date, 0, p_amount, p_narration, v_voucher, c_v_type, 'money_movement');
    END IF;

    RETURN json_build_object('success', true, 'voucher', v_voucher);
END;
$$;

-- =================================================================
-- MIGRATION: 20260114000016_fix_audit_function.sql
-- PURPOSE: Fix Audit function to include Advance Accounts in Net Balance Check
-- VERIFIER: Google DeepMind
-- =================================================================

CREATE OR REPLACE FUNCTION audit_verify_customer_balance(p_customer_id UUID)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
    v_stored_bal NUMERIC;
    v_calc_bal NUMERIC;
    v_ar_id UUID;
    v_adv_id UUID;
BEGIN
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_adv_id FROM accounts WHERE slug = 'customer_advance';
    
    -- Get the stored O(1) balance
    SELECT current_balance INTO v_stored_bal FROM customers WHERE id = p_customer_id;
    
    -- Calculate derived balance from Ledger
    -- Net Balance = Sum(Dr - Cr) for both AR and Advance accounts
    -- AR (Asset): Dr - Cr is positive.
    -- Advance (Liability): Dr - Cr is negative.
    -- This sums correctly to the Net Position.
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0) + 
           (SELECT COALESCE(opening_balance, 0) FROM customers WHERE id = p_customer_id)
    INTO v_calc_bal
    FROM ledger_entries
    WHERE account_id IN (v_ar_id, v_adv_id) -- FIXED: Include Advance Account
    AND reference_type IN ('sale', 'payment', 'money_movement')
    AND reference_id = p_customer_id;
    
    IF v_stored_bal != v_calc_bal THEN
        RAISE EXCEPTION 'CRITICAL INTEGRITY FAILURE: Customer % Stored Balance (%) != Ledger Balance (%)', 
            p_customer_id, v_stored_bal, v_calc_bal;
    END IF;
    
    RETURN json_build_object('status', 'OK', 'balance', v_stored_bal);
END;
$$;

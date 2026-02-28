-- Migration: Secure Account Creation with Dynamic Opening Balance
-- This SQL function ensures account creation and opening balance entries are Atomic (all-or-nothing).

CREATE OR REPLACE FUNCTION public.create_secure_account_v1(
    p_name TEXT, 
    p_type TEXT, 
    p_sub_category TEXT, 
    p_opening_balance NUMERIC,
    p_user_id UUID DEFAULT NULL
) RETURNS json AS $$
DECLARE 
    v_account_id UUID;
    v_equity_id UUID;
    v_new_code TEXT;
    v_code_prefix TEXT;
    v_max_code_val INT;
    v_voucher TEXT;
BEGIN
    -- Determine Prefix based on Type
    IF p_type = 'asset' THEN
        v_code_prefix := '1';
    ELSIF p_type = 'expense' THEN
        v_code_prefix := '5';
    ELSIF p_type = 'liability' THEN
        v_code_prefix := '2';
    ELSIF p_type = 'income' THEN
        v_code_prefix := '4';
    ELSIF p_type = 'equity' THEN
        v_code_prefix := '3';
    ELSE
        v_code_prefix := '9';
    END IF;

    -- Generate Next Sequence for Code securely
    SELECT COALESCE(MAX(NULLIF(regexp_replace(code, '\D', '', 'g'), '')::INT), (v_code_prefix || '000')::INT)
    INTO v_max_code_val
    FROM public.accounts
    WHERE code LIKE v_code_prefix || '%';

    v_new_code := (v_max_code_val + 1)::TEXT;

    -- 1. Insert Account
    INSERT INTO public.accounts (name, code, account_type, sub_category, is_active) 
    VALUES (p_name, v_new_code, p_type, p_sub_category, true) 
    RETURNING id INTO v_account_id;
    
    -- 2. Handle Opening Balance if provided and != 0 (Atomic Ledger Entry)
    IF p_opening_balance != 0 THEN
        -- Find the Capital/Equity account for the offset
        SELECT id INTO v_equity_id FROM public.accounts WHERE slug = 'capital' LIMIT 1;
        
        IF v_equity_id IS NULL THEN
             RAISE EXCEPTION 'CRITICAL: Capital account (slug: capital) not found for balancing entry.';
        END IF;

        -- Generate unique opening voucher
        v_voucher := 'OPEN-ACC-' || to_char(NOW(), 'YYMMDDHH24MISSMS');
        
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
        (v_voucher, 'opening', CURRENT_DATE, v_account_id, CASE WHEN p_opening_balance > 0 THEN p_opening_balance ELSE 0 END, CASE WHEN p_opening_balance < 0 THEN ABS(p_opening_balance) ELSE 0 END, 'Opening Balance Initialization: ' || p_name, p_user_id),
        (v_voucher, 'opening', CURRENT_DATE, v_equity_id, CASE WHEN p_opening_balance < 0 THEN ABS(p_opening_balance) ELSE 0 END, CASE WHEN p_opening_balance > 0 THEN p_opening_balance ELSE 0 END, 'Equity Offset for ' || p_name, p_user_id);
    END IF;
    
    RETURN json_build_object('success', true, 'account_id', v_account_id, 'code', v_new_code);
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Account Name or Generated Code Already Exists.';
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Transaction failed: %', SQLERRM;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

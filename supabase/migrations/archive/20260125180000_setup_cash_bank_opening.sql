-- ============================================================================
-- OPENING BALANCE SETUP - Backend Function
-- ============================================================================
-- This function allows setting opening balances via UI
-- ============================================================================

BEGIN;

-- Create or replace the opening balance setup function
CREATE OR REPLACE FUNCTION setup_opening_balances(
    p_cash_amount NUMERIC,
    p_bank_amount NUMERIC,
    p_opening_date DATE
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_cash_account_id UUID;
    v_bank_account_id UUID;
    v_capital_account_id UUID;
    v_voucher_cash TEXT;
    v_voucher_bank TEXT;
    v_current_user UUID;
    v_result JSON;
BEGIN
    -- Validate amounts
    IF p_cash_amount < 0 OR p_bank_amount < 0 THEN
        RAISE EXCEPTION 'Opening balances cannot be negative';
    END IF;
    
    IF p_cash_amount = 0 AND p_bank_amount = 0 THEN
        RAISE EXCEPTION 'At least one opening balance must be greater than zero';
    END IF;
    
    -- Get current user
    v_current_user := auth.uid();
    IF v_current_user IS NULL THEN
        RAISE EXCEPTION 'User must be authenticated';
    END IF;
    
    -- Get account IDs
    SELECT id INTO v_cash_account_id FROM accounts WHERE code = '1000' LIMIT 1;
    SELECT id INTO v_bank_account_id FROM accounts WHERE code = '1010' LIMIT 1;
    SELECT id INTO v_capital_account_id FROM accounts WHERE code = '3000' LIMIT 1;
    
    -- Check if accounts exist
    IF v_cash_account_id IS NULL THEN
        RAISE EXCEPTION 'Cash account (1000) not found';
    END IF;
    
    IF p_bank_amount > 0 AND v_bank_account_id IS NULL THEN
        RAISE EXCEPTION 'Bank account (1010) not found';
    END IF;
    
    -- If Capital account doesn't exist, create it
    IF v_capital_account_id IS NULL THEN
        INSERT INTO accounts (code, name, account_type, is_system, is_active)
        VALUES ('3000', 'Owner''s Capital', 'equity', true, true)
        RETURNING id INTO v_capital_account_id;
    END IF;
    
    -- Generate voucher numbers
    v_voucher_cash := 'OPEN-CASH-' || to_char(p_opening_date, 'YYYYMMDD');
    v_voucher_bank := 'OPEN-BANK-' || to_char(p_opening_date, 'YYYYMMDD');
    
    -- Check if opening balances already exist
    IF EXISTS (
        SELECT 1 FROM ledger_entries 
        WHERE voucher_no IN (v_voucher_cash, v_voucher_bank)
    ) THEN
        RAISE EXCEPTION 'Opening balances already exist. Please delete existing entries first.';
    END IF;
    
    -- Temporarily disable trigger
    EXECUTE 'ALTER TABLE ledger_entries DISABLE TRIGGER trg_check_account_balance';
    
    BEGIN
        -- ====================================================================
        -- CASH OPENING BALANCE
        -- ====================================================================
        IF p_cash_amount > 0 THEN
            -- Debit: Cash Account
            INSERT INTO ledger_entries (
                voucher_no, voucher_type, posting_date, account_id,
                debit_amount, credit_amount, narration, created_by
            ) VALUES (
                v_voucher_cash, 'opening', p_opening_date, v_cash_account_id,
                p_cash_amount, 0, 'Opening Balance - Cash on Hand', v_current_user
            );
            
            -- Credit: Capital Account
            INSERT INTO ledger_entries (
                voucher_no, voucher_type, posting_date, account_id,
                debit_amount, credit_amount, narration, created_by
            ) VALUES (
                v_voucher_cash, 'opening', p_opening_date, v_capital_account_id,
                0, p_cash_amount, 'Opening Balance - Cash on Hand', v_current_user
            );
        END IF;
        
        -- ====================================================================
        -- BANK OPENING BALANCE
        -- ====================================================================
        IF p_bank_amount > 0 THEN
            -- Debit: Bank Account
            INSERT INTO ledger_entries (
                voucher_no, voucher_type, posting_date, account_id,
                debit_amount, credit_amount, narration, created_by
            ) VALUES (
                v_voucher_bank, 'opening', p_opening_date, v_bank_account_id,
                p_bank_amount, 0, 'Opening Balance - Bank Account', v_current_user
            );
            
            -- Credit: Capital Account
            INSERT INTO ledger_entries (
                voucher_no, voucher_type, posting_date, account_id,
                debit_amount, credit_amount, narration, created_by
            ) VALUES (
                v_voucher_bank, 'opening', p_opening_date, v_capital_account_id,
                0, p_bank_amount, 'Opening Balance - Bank Account', v_current_user
            );
        END IF;
        
        -- Re-enable trigger
        EXECUTE 'ALTER TABLE ledger_entries ENABLE TRIGGER trg_check_account_balance';
        
        -- Build success response
        v_result := json_build_object(
            'success', true,
            'message', 'Opening balances created successfully',
            'cash_amount', p_cash_amount,
            'bank_amount', p_bank_amount,
            'total_capital', p_cash_amount + p_bank_amount,
            'voucher_cash', v_voucher_cash,
            'voucher_bank', v_voucher_bank
        );
        
        RETURN v_result;
        
    EXCEPTION WHEN OTHERS THEN
        -- Re-enable trigger on error
        EXECUTE 'ALTER TABLE ledger_entries ENABLE TRIGGER trg_check_account_balance';
        RAISE;
    END;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION setup_opening_balances(NUMERIC, NUMERIC, DATE) TO authenticated;

COMMIT;

-- ============================================================================
-- Test the function (commented out - uncomment to test)
-- ============================================================================
-- SELECT setup_opening_balances(100000, 500000, '2025-12-31');

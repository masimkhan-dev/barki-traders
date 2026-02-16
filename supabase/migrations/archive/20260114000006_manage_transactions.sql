-- Unified Transaction Management Function (Simplified)
-- Handles all transaction types: Sale, Purchase, Receipt, Payment
-- No advance payment logic - straightforward received/sent tracking only

-- First, add 'manage_transaction' to the voucher_type enum
ALTER TYPE public.voucher_type ADD VALUE IF NOT EXISTS 'manage_transaction';

CREATE OR REPLACE FUNCTION create_manage_transaction(
    p_transaction_type TEXT,    -- 'sale', 'purchase', 'receipt', 'payment'
    p_from_type TEXT,           -- 'cash', 'bank', 'entity'
    p_from_entity_id UUID,      -- Customer/Supplier ID if from is entity
    p_to_type TEXT,             -- 'cash', 'bank', 'entity'
    p_to_entity_id UUID,        -- Customer/Supplier ID if to is entity
    p_amount NUMERIC,
    p_narration TEXT,
    p_transaction_date DATE
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_voucher_no TEXT;
    v_debit_account_id UUID;
    v_credit_account_id UUID;
    v_cash_account_id UUID;
    v_bank_account_id UUID;
    v_ar_account_id UUID;
    v_ap_account_id UUID;
    v_result json;
BEGIN
    -- Generate voucher number
    v_voucher_no := 'MT-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
    
    -- Get standard account IDs
    SELECT id INTO v_cash_account_id FROM accounts WHERE code = '1000';
    SELECT id INTO v_bank_account_id FROM accounts WHERE code = '1010';
    SELECT id INTO v_ar_account_id FROM accounts WHERE code = '1100';
    SELECT id INTO v_ap_account_id FROM accounts WHERE code = '2000';
    
    -- CASE 1: RECEIPT (Customer → Cash/Bank)
    -- Dr: Cash/Bank, Cr: Accounts Receivable
    IF p_transaction_type = 'receipt' THEN
        IF p_to_type = 'cash' THEN
            v_debit_account_id := v_cash_account_id;
        ELSIF p_to_type = 'bank' THEN
            v_debit_account_id := v_bank_account_id;
        ELSE
            RAISE EXCEPTION 'Receipt must go to Cash or Bank';
        END IF;
        
        v_credit_account_id := v_ar_account_id;
        
        INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, created_by)
        VALUES 
            (v_debit_account_id, p_transaction_date, p_amount, 0, 
             'Receipt: ' || COALESCE(p_narration, 'Customer payment'), v_voucher_no, 'manage_transaction', 'manage_transaction', auth.uid()),
            (v_credit_account_id, p_transaction_date, 0, p_amount, 
             'Receipt: ' || COALESCE(p_narration, 'Customer payment'), v_voucher_no, 'manage_transaction', 'manage_transaction', auth.uid());
    
    -- CASE 2: PAYMENT (Cash/Bank → Supplier)
    -- Dr: Accounts Payable, Cr: Cash/Bank
    ELSIF p_transaction_type = 'payment' THEN
        v_debit_account_id := v_ap_account_id;
        
        IF p_from_type = 'cash' THEN
            v_credit_account_id := v_cash_account_id;
        ELSIF p_from_type = 'bank' THEN
            v_credit_account_id := v_bank_account_id;
        ELSE
            RAISE EXCEPTION 'Payment must come from Cash or Bank';
        END IF;
        
        INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, created_by)
        VALUES 
            (v_debit_account_id, p_transaction_date, p_amount, 0, 
             'Payment: ' || COALESCE(p_narration, 'Supplier payment'), v_voucher_no, 'manage_transaction', 'manage_transaction', auth.uid()),
            (v_credit_account_id, p_transaction_date, 0, p_amount, 
             'Payment: ' || COALESCE(p_narration, 'Supplier payment'), v_voucher_no, 'manage_transaction', 'manage_transaction', auth.uid());
    
    -- CASE 3: CREDIT SALE (Entity → Customer creates AR)
    -- Dr: Accounts Receivable, Cr: Sales Revenue
    -- Note: This is just the AR posting, actual sale entry should go through Sales module for inventory/COGS
    ELSIF p_transaction_type = 'sale' THEN
        v_debit_account_id := v_ar_account_id;
        
        -- Get Sales Revenue account
        SELECT id INTO v_credit_account_id FROM accounts WHERE code = '4000';
        
        INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, created_by)
        VALUES 
            (v_debit_account_id, p_transaction_date, p_amount, 0, 
             'Sale: ' || COALESCE(p_narration, 'Credit sale'), v_voucher_no, 'manage_transaction', 'manage_transaction', auth.uid()),
            (v_credit_account_id, p_transaction_date, 0, p_amount, 
             'Sale: ' || COALESCE(p_narration, 'Credit sale'), v_voucher_no, 'manage_transaction', 'manage_transaction', auth.uid());
    
    -- CASE 4: CREDIT PURCHASE (Supplier → Entity creates AP)
    -- Dr: Inventory, Cr: Accounts Payable
    -- Note: This is just the AP posting, actual purchase should go through Purchases module for inventory
    ELSIF p_transaction_type = 'purchase' THEN
        -- Get Inventory account
        SELECT id INTO v_debit_account_id FROM accounts WHERE code = '1200';
        v_credit_account_id := v_ap_account_id;
        
        INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, created_by)
        VALUES 
            (v_debit_account_id, p_transaction_date, p_amount, 0, 
             'Purchase: ' || COALESCE(p_narration, 'Credit purchase'), v_voucher_no, 'manage_transaction', 'manage_transaction', auth.uid()),
            (v_credit_account_id, p_transaction_date, 0, p_amount, 
             'Purchase: ' || COALESCE(p_narration, 'Credit purchase'), v_voucher_no, 'manage_transaction', 'manage_transaction', auth.uid());
    
    ELSE
        RAISE EXCEPTION 'Invalid transaction type: %', p_transaction_type;
    END IF;
    
    -- Return success
    SELECT json_build_object(
        'success', true,
        'voucher_no', v_voucher_no,
        'message', 'Transaction recorded successfully',
        'transaction_type', p_transaction_type
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION create_manage_transaction TO authenticated;

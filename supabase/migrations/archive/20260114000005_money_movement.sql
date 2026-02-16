-- Money Movement Function (Unified Transaction Entry for Munshi)
-- This function handles any money transfer between accounts and automatically creates proper double-entry postings

CREATE OR REPLACE FUNCTION create_money_movement(
    p_from_type TEXT,           -- 'cash', 'bank', 'customer', 'supplier'
    p_from_party_id UUID,       -- Customer/Supplier ID if applicable
    p_to_type TEXT,             -- 'cash', 'bank', 'customer', 'supplier'
    p_to_party_id UUID,         -- Customer/Supplier ID if applicable
    p_amount NUMERIC,
    p_narration TEXT,
    p_movement_date DATE
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_voucher_no TEXT;
    v_debit_account_id UUID;
    v_credit_account_id UUID;
    v_customer_ar_balance NUMERIC;
    v_supplier_ap_balance NUMERIC;
    v_payment_to_ar NUMERIC;
    v_payment_to_advance NUMERIC;
    v_result json;
BEGIN
    -- Generate voucher number
    v_voucher_no := 'MM-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
    
    -- CASE 1: Customer Payment (FROM Customer TO Cash/Bank)
    IF p_from_type = 'customer' AND (p_to_type = 'cash' OR p_to_type = 'bank') THEN
        -- Get Customer's AR Balance
        SELECT COALESCE(SUM(CASE WHEN a.code = '1100' THEN le.debit_amount - le.credit_amount ELSE 0 END), 0)
        INTO v_customer_ar_balance
        FROM ledger_entries le
        JOIN accounts a ON le.account_id = a.id
        LEFT JOIN sales s ON le.reference_type = 'sale' AND le.reference_id = s.id
        LEFT JOIN payments px ON le.reference_type = 'payment' AND le.reference_id = px.id
        WHERE a.code IN ('1100', '2100')
          AND (s.customer_id = p_from_party_id OR (px.party_id = p_from_party_id AND px.party_type = 'customer'));
        
        -- Calculate split
        IF p_amount <= v_customer_ar_balance THEN
            v_payment_to_ar := p_amount;
            v_payment_to_advance := 0;
        ELSE
            v_payment_to_ar := v_customer_ar_balance;
            v_payment_to_advance := p_amount - v_customer_ar_balance;
        END IF;
        
        -- Get account IDs
        SELECT id INTO v_debit_account_id FROM accounts WHERE code = (CASE WHEN p_to_type = 'cash' THEN '1000' ELSE '1010' END);
        
        -- Dr Cash/Bank, Cr AR
        IF v_payment_to_ar > 0 THEN
            SELECT id INTO v_credit_account_id FROM accounts WHERE code = '1100';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type)
            VALUES 
                (v_debit_account_id, p_movement_date, v_payment_to_ar, 0, COALESCE(p_narration, 'Customer Receipt'), v_voucher_no, 'money_movement'),
                (v_credit_account_id, p_movement_date, 0, v_payment_to_ar, COALESCE(p_narration, 'Customer Receipt'), v_voucher_no, 'money_movement');
        END IF;
        
        -- Dr Cash/Bank, Cr Customer Advance
        IF v_payment_to_advance > 0 THEN
            SELECT id INTO v_credit_account_id FROM accounts WHERE code = '2100';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type)
            VALUES 
                (v_debit_account_id, p_movement_date, v_payment_to_advance, 0, 'Customer Advance - ' || COALESCE(p_narration, ''), v_voucher_no, 'money_movement'),
                (v_credit_account_id, p_movement_date, 0, v_payment_to_advance, 'Customer Advance - ' || COALESCE(p_narration, ''), v_voucher_no, 'money_movement');
        END IF;
    
    -- CASE 2: Supplier Payment (FROM Cash/Bank TO Supplier)
    ELSIF (p_from_type = 'cash' OR p_from_type = 'bank') AND p_to_type = 'supplier' THEN
        -- Get Supplier's AP Balance
        SELECT COALESCE(SUM(CASE WHEN a.code = '2000' THEN le.credit_amount - le.debit_amount ELSE 0 END), 0)
        INTO v_supplier_ap_balance
        FROM ledger_entries le
        JOIN accounts a ON le.account_id = a.id
        LEFT JOIN purchases pur ON le.reference_type = 'purchase' AND le.reference_id = pur.id
        LEFT JOIN payments px ON le.reference_type = 'payment' AND le.reference_id = px.id
        WHERE a.code IN ('2000', '1110')
          AND (pur.supplier_id = p_to_party_id OR (px.party_id = p_to_party_id AND px.party_type = 'supplier'));
        
        -- Calculate split
        IF p_amount <= v_supplier_ap_balance THEN
            v_payment_to_ar := p_amount; -- Reusing var for AP
            v_payment_to_advance := 0;
        ELSE
            v_payment_to_ar := v_supplier_ap_balance;
            v_payment_to_advance := p_amount - v_supplier_ap_balance;
        END IF;
        
        -- Get account IDs
        SELECT id INTO v_credit_account_id FROM accounts WHERE code = (CASE WHEN p_from_type = 'cash' THEN '1000' ELSE '1010' END);
        
        -- Dr AP, Cr Cash/Bank
        IF v_payment_to_ar > 0 THEN
            SELECT id INTO v_debit_account_id FROM accounts WHERE code = '2000';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type)
            VALUES 
                (v_debit_account_id, p_movement_date, v_payment_to_ar, 0, COALESCE(p_narration, 'Supplier Payment'), v_voucher_no, 'money_movement'),
                (v_credit_account_id, p_movement_date, 0, v_payment_to_ar, COALESCE(p_narration, 'Supplier Payment'), v_voucher_no, 'money_movement');
        END IF;
        
        -- Dr Supplier Advance, Cr Cash/Bank
        IF v_payment_to_advance > 0 THEN
            SELECT id INTO v_debit_account_id FROM accounts WHERE code = '1110';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type)
            VALUES 
                (v_debit_account_id, p_movement_date, v_payment_to_advance, 0, 'Supplier Advance - ' || COALESCE(p_narration, ''), v_voucher_no, 'money_movement'),
                (v_credit_account_id, p_movement_date, 0, v_payment_to_advance, 'Supplier Advance - ' || COALESCE(p_narration, ''), v_voucher_no, 'money_movement');
        END IF;
    
    -- CASE 3: Cash to Bank Transfer
    ELSIF p_from_type = 'cash' AND p_to_type = 'bank' THEN
        SELECT id INTO v_debit_account_id FROM accounts WHERE code = '1010'; -- Bank
        SELECT id INTO v_credit_account_id FROM accounts WHERE code = '1000'; -- Cash
        
        INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type)
        VALUES 
            (v_debit_account_id, p_movement_date, p_amount, 0, 'Cash Deposit - ' || COALESCE(p_narration, ''), v_voucher_no, 'money_movement'),
            (v_credit_account_id, p_movement_date, 0, p_amount, 'Cash Deposit - ' || COALESCE(p_narration, ''), v_voucher_no, 'money_movement');
    
    -- CASE 4: Bank to Cash Transfer
    ELSIF p_from_type = 'bank' AND p_to_type = 'cash' THEN
        SELECT id INTO v_debit_account_id FROM accounts WHERE code = '1000'; -- Cash
        SELECT id INTO v_credit_account_id FROM accounts WHERE code = '1010'; -- Bank
        
        INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type)
        VALUES 
            (v_debit_account_id, p_movement_date, p_amount, 0, 'Cash Withdrawal - ' || COALESCE(p_narration, ''), v_voucher_no, 'money_movement'),
            (v_credit_account_id, p_movement_date, 0, p_amount, 'Cash Withdrawal - ' || COALESCE(p_narration, ''), v_voucher_no, 'money_movement');
    
    ELSE
        RAISE EXCEPTION 'Unsupported money movement type: % to %', p_from_type, p_to_type;
    END IF;
    
    -- Return success
    SELECT json_build_object(
        'success', true,
        'voucher_no', v_voucher_no,
        'message', 'Money movement recorded successfully'
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;

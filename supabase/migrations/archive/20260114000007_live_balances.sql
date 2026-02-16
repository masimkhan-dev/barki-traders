-- Get Live Balances for Transaction Form
-- Shows: Customer Udhaar, Supplier Udhaar, Cash, Bank

CREATE OR REPLACE FUNCTION get_live_balances()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_cash_balance NUMERIC;
    v_bank_balance NUMERIC;
    v_total_ar NUMERIC; -- Customer Udhaar (Lena hai)
    v_total_ap NUMERIC; -- Supplier Udhaar (Dena hai)
    v_result json;
BEGIN
    -- Get Cash Balance (Dr - Cr)
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    INTO v_cash_balance
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE a.code = '1000';
    
    -- Get Bank Balance (Dr - Cr)
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    INTO v_bank_balance
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE a.code = '1010';
    
    -- Get Total AR (Customer Udhaar - Lena hai)
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    INTO v_total_ar
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE a.code = '1100';
    
    -- Get Total AP (Supplier Udhaar - Dena hai)
    SELECT COALESCE(SUM(credit_amount - debit_amount), 0)
    INTO v_total_ap
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE a.code = '2000';
    
    SELECT json_build_object(
        'cash_balance', v_cash_balance,
        'bank_balance', v_bank_balance,
        'customer_udhaar', v_total_ar,
        'supplier_udhaar', v_total_ap
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;

-- Get specific entity balance
CREATE OR REPLACE FUNCTION get_entity_balance(
    p_entity_id UUID,
    p_entity_type TEXT -- 'customer' or 'supplier'
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_entity_type = 'customer' THEN
        -- Customer balance from AR account
        SELECT COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
        INTO v_balance
        FROM ledger_entries le
        JOIN accounts a ON le.account_id = a.id
        LEFT JOIN sales s ON le.reference_type = 'sale' AND le.reference_id = s.id
        LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
        WHERE a.code = '1100'
          AND (s.customer_id = p_entity_id OR (p.party_id = p_entity_id AND p.party_type = 'customer'));
          
    ELSIF p_entity_type = 'supplier' THEN
        -- Supplier balance from AP account
        SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
        INTO v_balance
        FROM ledger_entries le
        JOIN accounts a ON le.account_id = a.id
        LEFT JOIN purchases pur ON le.reference_type = 'purchase' AND le.reference_id = pur.id
        LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
        WHERE a.code = '2000'
          AND (pur.supplier_id = p_entity_id OR (p.party_id = p_entity_id AND p.party_type = 'supplier'));
    ELSE
        v_balance := 0;
    END IF;
    
    RETURN v_balance;
END;
$$;

GRANT EXECUTE ON FUNCTION get_live_balances TO authenticated;
GRANT EXECUTE ON FUNCTION get_entity_balance TO authenticated;

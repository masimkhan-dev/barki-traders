DO $$
DECLARE
    v_acc_2000 UUID;
    v_acc_3000 UUID;
    v_user_id UUID;
    v_current_bal_2000 NUMERIC;
BEGIN
    -- 1. Get Accounts
    SELECT id INTO v_acc_2000 FROM accounts WHERE code = '2000';
    SELECT id INTO v_acc_3000 FROM accounts WHERE code = '3000';
    v_user_id := auth.uid();

    -- 2. Get Balance (+286,000 expected)
    SELECT SUM(debit_amount - credit_amount) INTO v_current_bal_2000
    FROM ledger_entries
    WHERE account_id = v_acc_2000 AND COALESCE(is_reversed, false) = false;

    RAISE NOTICE 'Current Balance of 2000 (Payable): %', v_current_bal_2000;

    -- Only fix if Positive (Debit)
    IF v_current_bal_2000 > 0 THEN
        
        -- 3. Credit Account 2000 to zero it out
        INSERT INTO ledger_entries (
            voucher_no, voucher_type, posting_date, account_id, 
            debit_amount, credit_amount, narration, created_by, is_reversed
        ) VALUES (
            'SYS-FIX-2000', 'adjustment', CURRENT_DATE, v_acc_2000, 
            0, v_current_bal_2000, -- Credit
            'System Correction: Resetting Accounts Payable', v_user_id, false
        );

        -- 4. Debit Owner Equity (Reverse the previous offset)
        INSERT INTO ledger_entries (
            voucher_no, voucher_type, posting_date, account_id, 
            debit_amount, credit_amount, narration, created_by, is_reversed
        ) VALUES (
            'SYS-FIX-2000', 'adjustment', CURRENT_DATE, v_acc_3000, 
            v_current_bal_2000, 0, -- Debit
            'System Correction: Offset from 2000', v_user_id, false
        );
        
        RAISE NOTICE '✅ Successfully fixed Account 2000 and balanced Equity.';
    ELSE
        RAISE NOTICE '⚠️ Account 2000 isn''t positive. No fix applied.';
    END IF;

END $$;

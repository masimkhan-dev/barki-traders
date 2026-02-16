DO $$
DECLARE
    v_acc_3000 UUID;
    v_user_id UUID;
BEGIN
    SELECT id INTO v_acc_3000 FROM accounts WHERE code = '3000';
    v_user_id := auth.uid();

    -- 1. Fix SYS-AUTO-FIX (Needs Credit 40k) - VISIBLE entry
    INSERT INTO ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, 
        debit_amount, credit_amount, narration, created_by, is_reversed
    ) VALUES (
        'SYS-AUTO-FIX', 'adjustment', CURRENT_DATE, v_acc_3000, 
        0, 40000, 
        'System Correction: Balancing Entry (Confirmed)', v_user_id, 
        false -- <--- CRITICAL CHANGE
    );

    -- 2. Fix ADJ-MIGRATION (Needs Debit 40k) - VISIBLE entry
    INSERT INTO ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, 
        debit_amount, credit_amount, narration, created_by, is_reversed
    ) VALUES (
        'ADJ-MIGRATION', 'adjustment', CURRENT_DATE, v_acc_3000, 
        40000, 0, 
        'System Correction: Balancing Entry (Confirmed)', v_user_id, 
        false -- <--- CRITICAL CHANGE
    );

    RAISE NOTICE '✅ Correctly neutralized vouchers with visible entries.';
END $$;

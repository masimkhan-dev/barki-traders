-- CLEAN UP AR/AP CONTROL ACCOUNTS
-- Purpose: Zero out AR/AP control accounts since we use party balances instead.
-- This will remove the "Suspense" line items from the Balance Sheet.

BEGIN;

-- Disable trigger temporarily
SET session_replication_role = 'replica';

DO $$
DECLARE
    v_ar_account_id UUID;
    v_ap_account_id UUID;
    v_ar_balance NUMERIC;
    v_ap_balance NUMERIC;
    v_voucher TEXT;
BEGIN
    -- Get AR/AP account IDs and balances
    SELECT id, COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id), 0)
    INTO v_ar_account_id, v_ar_balance
    FROM accounts a WHERE slug = 'ar';

    SELECT id, COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id), 0)
    INTO v_ap_account_id, v_ap_balance
    FROM accounts a WHERE slug = 'ap';

    v_voucher := 'CLEANUP-' || to_char(now(), 'MMDDSS');

    -- Zero out AR (if positive, credit it; if negative, debit it)
    IF v_ar_balance != 0 THEN
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
        VALUES (
            v_voucher, 
            'adjustment', 
            '2026-01-01',
            v_ar_account_id,
            CASE WHEN v_ar_balance < 0 THEN ABS(v_ar_balance) ELSE 0 END,
            CASE WHEN v_ar_balance > 0 THEN v_ar_balance ELSE 0 END,
            'AR Control Account Cleanup (Switch to Party-Based Accounting)',
            auth.uid()
        );
    END IF;

    -- Zero out AP
    IF v_ap_balance != 0 THEN
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
        VALUES (
            v_voucher,
            'adjustment',
            '2026-01-01',
            v_ap_account_id,
            CASE WHEN v_ap_balance < 0 THEN ABS(v_ap_balance) ELSE 0 END,
            CASE WHEN v_ap_balance > 0 THEN v_ap_balance ELSE 0 END,
            'AP Control Account Cleanup (Switch to Party-Based Accounting)',
            auth.uid()
        );
    END IF;

    RAISE NOTICE '✅ AR/AP Control Accounts Zeroed: AR=%, AP=%', v_ar_balance, v_ap_balance;
END $$;

-- Re-enable triggers
SET session_replication_role = 'origin';

COMMIT;

-- Verify
SELECT 'AR Balance After Cleanup' as check_name, SUM(debit_amount - credit_amount) as balance FROM ledger_entries WHERE account_id = (SELECT id FROM accounts WHERE slug = 'ar')
UNION ALL
SELECT 'AP Balance After Cleanup', SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = (SELECT id FROM accounts WHERE slug = 'ap');

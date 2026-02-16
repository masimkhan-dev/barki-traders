
-- FORCE CAPSULE: ADD CAPITAL (BYPASS TRIGGER)
-- Purpose: Temporarily disable the validation trigger to allow Manual Capital Entry.

BEGIN;

-- 1. Disable the Trigger (Safety Bypass)
ALTER TABLE ledger_entries DISABLE TRIGGER ALL;

-- 2. Perform the Insert (Manual Journal)
DO $$
DECLARE
    v_capital_account_id UUID;
    v_cash_account_id UUID;
    v_voucher_no TEXT;
    v_amount NUMERIC := 5000000; -- 50 Lakh
BEGIN
    -- Get IDs
    SELECT id INTO v_capital_account_id FROM accounts WHERE slug = 'owner-capital' OR name ILIKE '%Capital%' LIMIT 1;
    SELECT id INTO v_cash_account_id FROM accounts WHERE slug = 'cash' OR name ILIKE '%Cash on Hand%' LIMIT 1;
    
    -- Create Account if missing
    IF v_capital_account_id IS NULL THEN
        INSERT INTO accounts (name, code, account_type, slug, is_active, is_system)
        VALUES ('Owner''s Capital', '3001', 'equity', 'owner-capital', true, true)
        RETURNING id INTO v_capital_account_id;
    END IF;

    v_voucher_no := 'CAP-' || to_char(now(), 'MMDDSS');

    -- Insert Credit (Capital Increases)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'adjustment', '2026-01-01', v_capital_account_id, 0, v_amount, 'Initial Capital Inv.', auth.uid());

    -- Insert Debit (Cash Increases)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'adjustment', '2026-01-01', v_cash_account_id, v_amount, 0, 'Capital Introduced (Cash)', auth.uid());

    RAISE NOTICE '✅ Capital Entry Force-Inserted: %', v_voucher_no;
END $$;

-- 3. Re-enable the Trigger (Restore Security)
ALTER TABLE ledger_entries ENABLE TRIGGER ALL;

COMMIT;

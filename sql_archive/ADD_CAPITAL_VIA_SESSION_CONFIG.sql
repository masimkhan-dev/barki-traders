
-- ADD CAPITAL VIA SESSION CONFIG
-- Purpose: Bypass triggers using session configuration (safer than ALTER TABLE in active transactions)

BEGIN;

-- 1. Disable Triggers for this session only
SET session_replication_role = 'replica';

-- 2. Insert Capital Entry
DO $$
DECLARE
    v_capital_account_id UUID;
    v_cash_account_id UUID;
    v_voucher_no TEXT;
    v_amount NUMERIC := 5000000; -- 50 Lakh
    v_date DATE := '2026-01-01';
BEGIN
    SELECT id INTO v_capital_account_id FROM accounts WHERE slug = 'owner-capital' OR name ILIKE '%Capital%' LIMIT 1;
    SELECT id INTO v_cash_account_id FROM accounts WHERE slug = 'cash' OR name ILIKE '%Cash on Hand%' LIMIT 1;
    
    IF v_capital_account_id IS NULL THEN
        INSERT INTO accounts (name, code, account_type, slug, is_active, is_system)
        VALUES ('Owner''s Capital', '3001', 'equity', 'owner-capital', true, true)
        RETURNING id INTO v_capital_account_id;
    END IF;

    v_voucher_no := 'CAP-' || to_char(now(), 'MMDDSS');

    -- CREDIT: Capital (Liability/Equity side)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'adjustment', v_date, v_capital_account_id, 0, v_amount, 'Initial Capital Investment', auth.uid());

    -- DEBIT: Cash (Asset side)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'adjustment', v_date, v_cash_account_id, v_amount, 0, 'Capital Introduced (Cash)', auth.uid());

    RAISE NOTICE '✅ Capital Entry Inserted (Triggers Bypassed): %', v_voucher_no;
END $$;

-- 3. Re-enable Triggers (Reset to default)
SET session_replication_role = 'origin';

COMMIT;

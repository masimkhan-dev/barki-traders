
-- BYPASS SPECIFIC TRIGGER FOR CAPITAL ENTRY
-- Purpose: Disable only the 'ensure_source_document_exists' trigger to allow manual entry.

BEGIN;

-- 1. Disable the Specific User Trigger (Not ALL)
ALTER TABLE ledger_entries DISABLE TRIGGER ensure_source_document_exists;

-- 2. Perform the Insert
DO $$
DECLARE
    v_capital_account_id UUID;
    v_cash_account_id UUID;
    v_voucher_no TEXT;
    v_amount NUMERIC := 5000000; -- 50 Lakh
BEGIN
    SELECT id INTO v_capital_account_id FROM accounts WHERE slug = 'owner-capital' OR name ILIKE '%Capital%' LIMIT 1;
    SELECT id INTO v_cash_account_id FROM accounts WHERE slug = 'cash' OR name ILIKE '%Cash on Hand%' LIMIT 1;
    
    IF v_capital_account_id IS NULL THEN
        INSERT INTO accounts (name, code, account_type, slug, is_active, is_system)
        VALUES ('Owner''s Capital', '3001', 'equity', 'owner-capital', true, true)
        RETURNING id INTO v_capital_account_id;
    END IF;

    v_voucher_no := 'CAP-' || to_char(now(), 'MMDDSS');

    -- Credit Capital
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'adjustment', '2026-01-01', v_capital_account_id, 0, v_amount, 'Initial Capital Inv.', auth.uid());

    -- Debit Cash
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'adjustment', '2026-01-01', v_cash_account_id, v_amount, 0, 'Capital Introduced (Cash)', auth.uid());

    RAISE NOTICE '✅ Capital Entry Inserted via Trigger Bypass: %', v_voucher_no;
END $$;

-- 3. Re-enable the Trigger
ALTER TABLE ledger_entries ENABLE TRIGGER ensure_source_document_exists;

COMMIT;

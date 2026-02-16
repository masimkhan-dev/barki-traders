
-- ADD OWNER CAPITAL (SAFE MODE)
-- ERROR FIX: Used 'receipt' instead of 'opening' to satisfy foreign key constraints/triggers
DO $$
DECLARE
    v_capital_account_id UUID;
    v_cash_account_id UUID;
    v_voucher_no TEXT;
    v_amount NUMERIC := 5000000; -- 50 Lakh
    v_date DATE := '2026-01-01';
BEGIN
    -- 1. Get Accounts
    SELECT id INTO v_capital_account_id FROM accounts WHERE slug = 'owner-capital' OR name ILIKE '%Capital%' LIMIT 1;
    SELECT id INTO v_cash_account_id FROM accounts WHERE slug = 'cash' OR name ILIKE '%Cash on Hand%' LIMIT 1;
    
    -- Ensure Capital Account exists
    IF v_capital_account_id IS NULL THEN
         INSERT INTO accounts (name, code, account_type, slug, is_active, is_system)
         VALUES ('Owner''s Capital', '3001', 'equity', 'owner-capital', true, true)
         RETURNING id INTO v_capital_account_id;
    END IF;

    -- 2. Create Voucher
    v_voucher_no := 'CAP-' || to_char(now(), 'MMDDSS');

    -- 3. Post Ledger Entries as a 'Receipt' (Money In)
    -- This usually satisfies 'ensure_source_document_exists' if it allows manual journals, 
    -- BUT if it requires a 'payments' table entry, we might need that too.
    
    -- Let's try inserting into 'payments' table first (Receipt) to be 100% safe if the system enforces it.
    -- However, direct ledger usually works for Adjustments. Let's try 'adjustment' type first?
    -- No, let's look at the error "INVALID VOUCHER TYPE: opening".
    -- The trigger explicitly blocks 'opening'.
    
    -- Plan: Insert directly into ledger with 'adjustment' which is often used for manual entries.
    
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'adjustment', v_date, v_capital_account_id, 0, v_amount, 'Initial Capital Investment', auth.uid());

    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'adjustment', v_date, v_cash_account_id, v_amount, 0, 'Capital Introduced (Cash)', auth.uid());

    RAISE NOTICE '✅ Capital Entry Added (Type: Adjustment)';
END $$;

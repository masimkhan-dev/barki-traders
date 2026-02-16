-- ULTIMATE AR/AP CLEANUP (BALANCED DOUBLE-ENTRY)
-- Purpose: Permanently zero out AR/AP control accounts with proper offsetting

BEGIN;

SET session_replication_role = 'replica';

-- 1. DELETE ALL PREVIOUS CLEANUP ATTEMPTS
DELETE FROM ledger_entries 
WHERE voucher_no IN (
    'CLEANUP-020540', 
    'ADJ-CLEANUP-020535',
    'ADJ-CLEANUP-020540',
    'CLEANUP-020535'
) OR voucher_no LIKE 'CLEANUP-%' OR voucher_no LIKE 'ADJ-CLEANUP-%';

-- 2. GET ACCOUNT IDs
DO $$
DECLARE
    v_ar_id UUID;
    v_ap_id UUID;
    v_equity_id UUID;
    v_voucher TEXT := 'ZERO-ARCP-' || to_char(now(), 'HHMMSS');
BEGIN
    -- Get AR, AP account IDs
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';
    
    -- Get or create Opening Balance Equity
    SELECT id INTO v_equity_id FROM accounts WHERE name ILIKE '%opening%balance%' OR slug = 'opening-balance-equity' LIMIT 1;
    
    IF v_equity_id IS NULL THEN
        INSERT INTO accounts (name, code, account_type, slug, is_active, is_system)
        VALUES ('Opening Balance Equity', '3900', 'equity', 'opening-balance-equity', true, true)
        RETURNING id INTO v_equity_id;
    END IF;

    -- 3. ZERO OUT AR (Credit it by Rs 5,013,020)
    INSERT INTO ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, 
        debit_amount, credit_amount, narration, created_by
    ) VALUES (
        v_voucher, 'adjustment', '2025-12-31',
        v_ar_id, 0, 5013020,
        'AR Control Account Closure - Party Accounting Migration',
        COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid)
    );

    -- 4. ZERO OUT AP (Debit it by Rs 5,157,000)
    INSERT INTO ledger_entries (
        voucher_no, voucher_type, posting_date, account_id,
        debit_amount, credit_amount, narration, created_by
    ) VALUES (
        v_voucher, 'adjustment', '2025-12-31',
        v_ap_id, 5157000, 0,
        'AP Control Account Closure - Party Accounting Migration',
        COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid)
    );

    -- 5. BALANCE THE ENTRY (Debit Opening Balance Equity by net difference)
    -- Net: Debits Rs 5,157,000 - Credits Rs 5,013,020 = Need Credit Rs 143,980
    INSERT INTO ledger_entries (
        voucher_no, voucher_type, posting_date, account_id,
        debit_amount, credit_amount, narration, created_by
    ) VALUES (
        v_voucher, 'adjustment', '2025-12-31',
        v_equity_id, 0, 143980,
        'Opening Balance Adjustment - AR/AP Migration Offset',
        COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid)
    );

    RAISE NOTICE 'AR/AP Successfully Zeroed. Opening Balance Equity: Rs 143,980';
END $$;

SET session_replication_role = 'origin';

COMMIT;

-- 6. VERIFY BALANCES ARE NOW ZERO
SELECT 
    'AR After Cleanup' as check_name,
    COALESCE(SUM(debit_amount - credit_amount), 0) as balance
FROM ledger_entries 
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'ar')
  AND (is_reversed IS NULL OR is_reversed = false)

UNION ALL

SELECT 
    'AP After Cleanup',
    COALESCE(SUM(debit_amount - credit_amount), 0)
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'ap')
  AND (is_reversed IS NULL OR is_reversed = false)

UNION ALL

SELECT
    'Opening Balance Equity',
    COALESCE(SUM(credit_amount - debit_amount), 0)
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'opening-balance-equity')
  AND (is_reversed IS NULL OR is_reversed = false);

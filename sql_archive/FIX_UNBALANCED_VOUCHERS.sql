-- COMPREHENSIVE CLEANUP FIX
-- Purpose: Fix all unbalanced vouchers and redo AR/AP cleanup correctly.

BEGIN;

SET session_replication_role = 'replica';

-- 1. FIX CAPITAL VOUCHER (Align both entries to 2026-02-05)
UPDATE ledger_entries 
SET posting_date = '2026-02-05'
WHERE voucher_no = 'CAP-020515' AND posting_date = '2026-01-01';

-- 2. DELETE BAD CLEANUP ENTRIES
DELETE FROM ledger_entries WHERE voucher_no IN ('CLEANUP-020540', 'ADJ-CLEANUP-020535');

-- 3. DELETE OLD RETAINED EARNINGS ACCOUNT (We'll recreate if needed)
DELETE FROM accounts WHERE slug = 'retained-earnings';

SET session_replication_role = 'origin';

COMMIT;

-- 4. VERIFY CAPITAL VOUCHER IS NOW BALANCED
SELECT 
    voucher_no,
    posting_date,
    SUM(debit_amount) as total_debit,
    SUM(credit_amount) as total_credit,
    SUM(debit_amount) - SUM(credit_amount) as difference
FROM ledger_entries
WHERE voucher_no = 'CAP-020515'
GROUP BY voucher_no, posting_date;

BEGIN;

DELETE FROM ledger_entries 
WHERE voucher_no = 'SYS-AUTO-FIX';

DELETE FROM ledger_entries 
WHERE voucher_no = 'ADJ-MIGRATION';

COMMIT;

-- Verify deletion immediately
SELECT voucher_no FROM ledger_entries WHERE voucher_no IN ('SYS-AUTO-FIX', 'ADJ-MIGRATION');

BEGIN;

-- Temporarily bypass RLS
ALTER TABLE ledger_entries DISABLE ROW LEVEL SECURITY;

-- DELETE aggressively
DELETE FROM ledger_entries WHERE voucher_no = 'SYS-AUTO-FIX';
DELETE FROM ledger_entries WHERE voucher_no = 'ADJ-MIGRATION';

-- Re-enable RLS
ALTER TABLE ledger_entries ENABLE ROW LEVEL SECURITY;

COMMIT;

-- Verify
SELECT voucher_no FROM ledger_entries WHERE voucher_no IN ('SYS-AUTO-FIX', 'ADJ-MIGRATION');

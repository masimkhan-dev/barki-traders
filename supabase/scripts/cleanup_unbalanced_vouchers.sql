BEGIN;

-- Remove the specific unbalanced temporary vouchers
DELETE FROM ledger_entries 
WHERE voucher_no IN ('SYS-AUTO-FIX', 'ADJ-MIGRATION');

COMMIT;

-- Print confirmation (Separate statement)
SELECT '✅ Cleaned up unbalanced temporary vouchers.' as status;

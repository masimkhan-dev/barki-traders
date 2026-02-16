BEGIN;

-- 1. Disable Triggers temporarily (to avoid recursion errors during mass delete)
ALTER TABLE ledger_entries DISABLE TRIGGER ALL;

-- 2. Clear Child Tables
TRUNCATE TABLE sales CASCADE;
TRUNCATE TABLE purchases CASCADE;
TRUNCATE TABLE payments CASCADE;

-- 3. Clear Ledger Entries EXCEPT Opening Balances
-- This removes all transactions, system fixes, and tests.
-- Only initial Cash/Bank opening entries remain.
DELETE FROM ledger_entries 
WHERE voucher_type NOT IN ('opening');

-- 4. Reset Party Balances to 0
UPDATE parties SET current_balance = 0;

-- 5. Enable Triggers back
ALTER TABLE ledger_entries ENABLE TRIGGER ALL;

-- 6. Verify what remains (Should only be Cash, Bank, Capital)
SELECT voucher_no, debit_amount, credit_amount, narration 
FROM ledger_entries;

COMMIT;

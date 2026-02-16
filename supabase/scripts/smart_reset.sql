BEGIN;

-- 1. Clear Child Tables
DELETE FROM sales;
DELETE FROM purchases;
DELETE FROM payments;

-- 2. Break Self-References in Ledger (to avoid FK errors on delete)
UPDATE ledger_entries SET prev_entry_hash = NULL;

-- 3. Delete Ledger Entries
DELETE FROM ledger_entries;

-- 4. Reset Balances
UPDATE parties SET current_balance = 0, opening_balance = 0;
UPDATE accounts SET opening_balance = 0;

COMMIT;

SELECT '🔥 SYSTEM RESET SUCCESSFUL.' as status;

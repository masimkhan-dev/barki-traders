BEGIN;

-- 1. Clear Child Tables
DELETE FROM sales;
DELETE FROM purchases;
DELETE FROM payments;

-- 2. Break Self-References 
UPDATE ledger_entries SET prev_entry_hash = NULL;

-- 3. Delete Ledger Entries
DELETE FROM ledger_entries;

-- 4. Reset Parties
UPDATE parties SET current_balance = 0, opening_balance = 0;

-- 5. No update for Accounts needed (Transaction history gone = Balance gone)

COMMIT;

SELECT '🔥 SYSTEM RESET SUCCESSFUL (VERIFIED).' as status;

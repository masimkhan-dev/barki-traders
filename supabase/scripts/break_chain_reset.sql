BEGIN;

-- 1. Break the Chain (Critical Step for Self-Referencing Table)
UPDATE ledger_entries SET prev_entry_hash = NULL;

-- 2. NOW Delete (Order matters: Child -> Parent)
DELETE FROM sales;
DELETE FROM purchases;
DELETE FROM payments;
DELETE FROM ledger_entries;

-- 3. Reset Balances
UPDATE parties SET current_balance = 0, opening_balance = 0;

COMMIT;

SELECT count(*) as remaining_ledger FROM ledger_entries;

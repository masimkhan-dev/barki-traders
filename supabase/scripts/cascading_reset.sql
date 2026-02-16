BEGIN;

-- 1. Clear Child Tables
DELETE FROM sales;
DELETE FROM purchases;
DELETE FROM payments;

-- 2. Clean Ledger
DELETE FROM ledger_entries;

-- 3. Reset Balances
UPDATE parties SET current_balance = 0, opening_balance = 0;

COMMIT;

SELECT count(*) as remaining_ledger FROM ledger_entries;

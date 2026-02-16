BEGIN;

-- 1. NUCLEAR FLUSH - Delete EVERYTHING using single TRUNCATE with CASCADE
TRUNCATE TABLE 
    ledger_entries,
    sales, 
    purchases, 
    payments 
CASCADE; 

-- 2. Reset Parties to Zero (Preserving the records, just resetting values)
-- Accounts does not have balance columns to reset (it is a master data table)
UPDATE parties SET current_balance = 0, opening_balance = 0;

-- 3. Confirmation and Sanity Check
SELECT 
    '🔥 SYSTEM RESET COMPLETE.' as status,
    (SELECT COUNT(*) FROM ledger_entries) as ledger_count,
    (SELECT COALESCE(SUM(current_balance), 0) FROM parties) as parties_balance;

COMMIT;

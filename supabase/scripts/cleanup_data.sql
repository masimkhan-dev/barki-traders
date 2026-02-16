-- CLEANUP SCRIPT: Deletes all transaction data and resets balances
-- Run this to start fresh for testing

BEGIN;

-- 1. Truncate transaction tables (Cascade to children)
TRUNCATE TABLE public.ledger_entries CASCADE;
TRUNCATE TABLE public.payments CASCADE;
TRUNCATE TABLE public.sales CASCADE;
TRUNCATE TABLE public.purchases CASCADE;

-- 2. Reset Party Balances
UPDATE public.parties 
SET opening_balance = 0;

-- 3. Reset Inventory (Updates the 'inventory' table, not fuel_types)
UPDATE public.inventory 
SET quantity = 0,
    avg_cost = 0;

COMMIT;

NOTIFY pgrst, 'reload config';

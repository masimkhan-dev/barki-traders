-- CLEANUP SCRIPT: Deletes all transaction data and resets balances
-- Run this to start fresh for testing

BEGIN;

-- 1. Truncate transaction tables (Cascade to children)
TRUNCATE TABLE public.ledger_entries CASCADE;
TRUNCATE TABLE public.payments CASCADE;
TRUNCATE TABLE public.sales CASCADE;
TRUNCATE TABLE public.purchases CASCADE;
-- TRUNCATE TABLE public.transaction_items CASCADE; -- If exists

-- 2. Reset Party Balances
UPDATE public.parties 
SET opening_balance = 0;

-- 3. Reset Inventory Stock
UPDATE public.fuel_types 
SET stock_quantity = 0; 
-- Note: 'opening_stock' column in fuel_types was removed/migrated in previous schemas, 
-- but if it exists, reset it too.
-- UPDATE public.fuel_types SET opening_stock = 0 WHERE EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='fuel_types' AND column_name='opening_stock');

COMMIT;

NOTIFY pgrst, 'reload config';

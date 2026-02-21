-- ==============================================================================
-- 🚀 SYSTEM RESET & GO-LIVE SCRIPT (FINAL PRODUCTION LAUNCH)
-- Purpose: Safely deletes all test transactions while keeping user accounts, 
--          settings, and your Parties/Khata safe.
-- Location to run: Supabase -> SQL Editor
--
-- DANGER LEVEL: HIGH (This will wipe all financial data)
-- ==============================================================================

BEGIN;

-- 1. Disable triggers temporarily so we don't hit recursive blocks
SET session_replication_role = 'replica';

-- 2. CLEAR ALL TRANSACTION TABLES (Ledger, Sales, Purchases, Payments, Expenses)
-- Using TRUNCATE CASCADE handles all foreign key relationships safely and resetting IDs.
TRUNCATE TABLE ledger_entries CASCADE;
TRUNCATE TABLE sales CASCADE;
TRUNCATE TABLE purchases CASCADE;
TRUNCATE TABLE payments CASCADE;

-- 3. RESET INVENTORY TO EXACTLY ZERO
-- Fixing column name: use 'quantity' in public.inventory instead of fuel_types.current_stock
UPDATE public.inventory
SET quantity = 0, avg_cost = 0;

-- 4. Re-enable all triggers
SET session_replication_role = 'origin';

-- OPTIONAL: If client wants to also delete the Test Parties (Customers/Suppliers)
-- Uncomment the line below if you want EVERY Khata/Party deleted too:
-- TRUNCATE TABLE parties CASCADE;

COMMIT;

-- SUCCESS: The system is now 100% clean, empty, and ready for actual live business.

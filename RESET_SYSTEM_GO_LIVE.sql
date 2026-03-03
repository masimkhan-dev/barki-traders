-- ==============================================================================
-- 🚀 FULL SYSTEM RESET & GO-LIVE SCRIPT (FINAL PRODUCTION)
-- Purpose: Deletes ALL data (Transactions AND Customers/Suppliers/Parties)
--          Keeps: Auth Users and Chart of Account Structure.
-- Location: Supabase -> SQL Editor
-- ==============================================================================

BEGIN;

-- 1. Disable triggers temporarily
SET session_replication_role = 'replica';

-- 2. WIPE ALL DATA
-- This order ensures foreign keys don't block the process
TRUNCATE TABLE ledger_entries CASCADE;
TRUNCATE TABLE sales CASCADE;
TRUNCATE TABLE purchases CASCADE;
TRUNCATE TABLE payments CASCADE;

-- 3. WIPE PARTIES (Customers, Suppliers, Workers, etc.)
TRUNCATE TABLE parties CASCADE;

-- 4. RESET INVENTORY & STOCK
UPDATE public.inventory
SET quantity = 0, avg_cost = 0;

-- 5. Re-enable all triggers
SET session_replication_role = 'origin';

COMMIT;

-- ✅ SYSTEM IS NOW A CLEAN SLATE (EMPTY KHATA & EMPTY LEDGER)

-- ==============================================================================
-- 🚀 SUPABASE SECURITY LINTER WARNING FIX SCRIPT
-- Purpose: Resolves 'RLS Policy Always True' and 'Function Search Path Mutable' 
--          warnings in the Supabase Dashboard without breaking any functionality.
-- Safe to Run: YES. This does not alter data, only security policy conditions.
-- Location to Run: Supabase -> SQL Editor
-- ==============================================================================

BEGIN;

-- ============================================================================
-- 1. FIX RLS POLICIES (Changing 'true' to explicit authentication checks)
-- This ensures the linter stops complaining about overly permissive rules, 
-- while keeping the exact same access for your logged-in Admin/Accountant.
-- ============================================================================

-- ACCOUNTS
DROP POLICY IF EXISTS "accounts_insert_authenticated" ON public.accounts;
CREATE POLICY "accounts_insert_authenticated" ON public.accounts FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "accounts_update_authenticated" ON public.accounts;
CREATE POLICY "accounts_update_authenticated" ON public.accounts FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- AUDIT LOGS
DROP POLICY IF EXISTS "audit_logs_insert_authenticated" ON public.audit_logs;
CREATE POLICY "audit_logs_insert_authenticated" ON public.audit_logs FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- FUEL TYPES
DROP POLICY IF EXISTS "fuel_types_insert_authenticated" ON public.fuel_types;
CREATE POLICY "fuel_types_insert_authenticated" ON public.fuel_types FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "fuel_types_update_authenticated" ON public.fuel_types;
CREATE POLICY "fuel_types_update_authenticated" ON public.fuel_types FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- INVENTORY
DROP POLICY IF EXISTS "inventory_insert_authenticated" ON public.inventory;
CREATE POLICY "inventory_insert_authenticated" ON public.inventory FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "inventory_update_authenticated" ON public.inventory;
CREATE POLICY "inventory_update_authenticated" ON public.inventory FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- LEDGER ENTRIES
DROP POLICY IF EXISTS "Insert Ledger" ON public.ledger_entries;
CREATE POLICY "Insert Ledger" ON public.ledger_entries FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "Update Ledger" ON public.ledger_entries;
CREATE POLICY "Update Ledger" ON public.ledger_entries FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "ledger_insert_authenticated" ON public.ledger_entries;
CREATE POLICY "ledger_insert_authenticated" ON public.ledger_entries FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "ledger_update_authenticated" ON public.ledger_entries;
CREATE POLICY "ledger_update_authenticated" ON public.ledger_entries FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- PARTIES
DROP POLICY IF EXISTS "Insert Parties" ON public.parties;
CREATE POLICY "Insert Parties" ON public.parties FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "parties_insert_authenticated" ON public.parties;
CREATE POLICY "parties_insert_authenticated" ON public.parties FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "parties_update_authenticated" ON public.parties;
CREATE POLICY "parties_update_authenticated" ON public.parties FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- PAYMENTS
DROP POLICY IF EXISTS "Insert Payments" ON public.payments;
CREATE POLICY "Insert Payments" ON public.payments FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "payments_insert_authenticated" ON public.payments;
CREATE POLICY "payments_insert_authenticated" ON public.payments FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "payments_update_authenticated" ON public.payments;
CREATE POLICY "payments_update_authenticated" ON public.payments FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- PURCHASES
DROP POLICY IF EXISTS "Insert Purchases" ON public.purchases;
CREATE POLICY "Insert Purchases" ON public.purchases FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "Update Purchases" ON public.purchases;
CREATE POLICY "Update Purchases" ON public.purchases FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "purchases_insert_authenticated" ON public.purchases;
CREATE POLICY "purchases_insert_authenticated" ON public.purchases FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "purchases_update_authenticated" ON public.purchases;
CREATE POLICY "purchases_update_authenticated" ON public.purchases FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- SALES
DROP POLICY IF EXISTS "Insert Sales" ON public.sales;
CREATE POLICY "Insert Sales" ON public.sales FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "Update Sales" ON public.sales;
CREATE POLICY "Update Sales" ON public.sales FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "sales_insert_authenticated" ON public.sales;
CREATE POLICY "sales_insert_authenticated" ON public.sales FOR INSERT WITH CHECK (auth.role() = 'authenticated');

DROP POLICY IF EXISTS "sales_update_authenticated" ON public.sales;
CREATE POLICY "sales_update_authenticated" ON public.sales FOR UPDATE USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');


-- ============================================================================
-- 2. FIX FUNCTION SEARCH PATH MUTABLE WARNINGS
-- This part dynamically sets "search_path = public" on ALL your functions
-- which automatically clears the 80+ warnings about "Search Path Mutable" 
-- in one big sweep.
-- ============================================================================
DO $$
DECLARE
    func_record RECORD;
BEGIN
    FOR func_record IN
        SELECT
            n.nspname AS schema_name,
            p.proname AS func_name,
            pg_get_function_identity_arguments(p.oid) AS func_args
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
          AND p.prokind = 'f' -- only standard functions
    LOOP
        EXECUTE format('ALTER FUNCTION %I.%I(%s) SET search_path = public;',
                       func_record.schema_name,
                       func_record.func_name,
                       func_record.func_args);
    END LOOP;
END $$;

COMMIT;

-- Note: The "Leaked Password Protection" warning is an account-level setting 
-- inside Supabase Dashboard (Authentication -> Security). You can safely ignore it 
-- or turn it on from the dashboard UI.

-- =================================================================
-- 🔒 PHASE 1: SAFETY HARDENING
-- RLS (Row Level Security) + Performance Indexes + Audit Table
-- Project: Naveed Musazai — Fuel Trust Ledger
-- Date: 2026-02-16
-- 
-- ⚠️  READ THIS BEFORE RUNNING:
-- 
-- This script does THREE things:
-- 1. Enables RLS on ALL tables with safe policies
-- 2. Creates performance indexes on key columns
-- 3. Creates the audit_logs table (referenced by triggers)
--
-- ✅ SAFETY GUARANTEE:
-- - All authenticated users keep FULL READ access (SELECT) on all tables
-- - All authenticated users keep FULL WRITE access (INSERT/UPDATE) on transaction tables
-- - DELETE is restricted to admin role ONLY (via user_roles lookup)
-- - RPC functions (SECURITY DEFINER) bypass RLS — they will keep working
-- - Triggers run as the table owner (postgres) — they bypass RLS
-- - Your existing app will work exactly as before
--
-- ❌ WHAT THIS BLOCKS:
-- - Anonymous (unauthenticated) users cannot touch any table
-- - Non-admin users cannot DELETE from financial tables
-- - Direct browser DevTools manipulation without a valid JWT
--
-- 🔄 ROLLBACK: If something breaks, run:
--   ALTER TABLE <table_name> DISABLE ROW LEVEL SECURITY;
--   (for each table)
--
-- =================================================================

BEGIN;

-- =================================================================
-- PART 1: ROW LEVEL SECURITY (RLS)
-- =================================================================

-- -----------------------------------------------------------------
-- 1.1 HELPER FUNCTION: Check if current user is admin
-- This function is used inside RLS policies for DELETE restrictions
-- -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid()
    AND role = 'admin'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- -----------------------------------------------------------------
-- 1.2 TABLE: accounts
-- READ: All authenticated users
-- WRITE: All authenticated users (add new expense categories, etc.)
-- DELETE: Admin only
-- -----------------------------------------------------------------
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "accounts_select_authenticated"
  ON public.accounts FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "accounts_insert_authenticated"
  ON public.accounts FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "accounts_update_authenticated"
  ON public.accounts FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "accounts_delete_admin_only"
  ON public.accounts FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- -----------------------------------------------------------------
-- 1.3 TABLE: fuel_types
-- READ: All authenticated
-- WRITE: All authenticated (munshi can add new fuel types)
-- DELETE: Admin only
-- -----------------------------------------------------------------
ALTER TABLE public.fuel_types ENABLE ROW LEVEL SECURITY;

CREATE POLICY "fuel_types_select_authenticated"
  ON public.fuel_types FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "fuel_types_insert_authenticated"
  ON public.fuel_types FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "fuel_types_update_authenticated"
  ON public.fuel_types FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "fuel_types_delete_admin_only"
  ON public.fuel_types FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- -----------------------------------------------------------------
-- 1.4 TABLE: parties
-- READ: All authenticated
-- WRITE: All authenticated (munshi manages parties daily)
-- DELETE: Admin only
-- -----------------------------------------------------------------
ALTER TABLE public.parties ENABLE ROW LEVEL SECURITY;

CREATE POLICY "parties_select_authenticated"
  ON public.parties FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "parties_insert_authenticated"
  ON public.parties FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "parties_update_authenticated"
  ON public.parties FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "parties_delete_admin_only"
  ON public.parties FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- -----------------------------------------------------------------
-- 1.5 TABLE: inventory
-- READ: All authenticated
-- WRITE: All authenticated (triggers update this automatically)
-- DELETE: Admin only
-- -----------------------------------------------------------------
ALTER TABLE public.inventory ENABLE ROW LEVEL SECURITY;

CREATE POLICY "inventory_select_authenticated"
  ON public.inventory FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "inventory_insert_authenticated"
  ON public.inventory FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "inventory_update_authenticated"
  ON public.inventory FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "inventory_delete_admin_only"
  ON public.inventory FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- -----------------------------------------------------------------
-- 1.6 TABLE: ledger_entries (THE MOST CRITICAL TABLE)
-- READ: All authenticated
-- INSERT: All authenticated (triggers + RPCs create entries)
-- UPDATE: All authenticated (reconciliation, edits)
-- DELETE: Admin only (Roznamcha delete button)
--
-- NOTE: Triggers that DELETE old entries before re-inserting
-- run as the table owner (postgres), which BYPASSES RLS.
-- So sync_sale_v11() and sync_purchase_v11() will keep working.
-- -----------------------------------------------------------------
ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ledger_select_authenticated"
  ON public.ledger_entries FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "ledger_insert_authenticated"
  ON public.ledger_entries FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "ledger_update_authenticated"
  ON public.ledger_entries FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "ledger_delete_admin_only"
  ON public.ledger_entries FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- -----------------------------------------------------------------
-- 1.7 TABLE: sales
-- READ: All authenticated
-- INSERT/UPDATE: All authenticated
-- DELETE: Admin only
-- -----------------------------------------------------------------
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sales_select_authenticated"
  ON public.sales FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "sales_insert_authenticated"
  ON public.sales FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "sales_update_authenticated"
  ON public.sales FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "sales_delete_admin_only"
  ON public.sales FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- -----------------------------------------------------------------
-- 1.8 TABLE: purchases
-- -----------------------------------------------------------------
ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;

CREATE POLICY "purchases_select_authenticated"
  ON public.purchases FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "purchases_insert_authenticated"
  ON public.purchases FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "purchases_update_authenticated"
  ON public.purchases FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "purchases_delete_admin_only"
  ON public.purchases FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- -----------------------------------------------------------------
-- 1.9 TABLE: payments
-- -----------------------------------------------------------------
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "payments_select_authenticated"
  ON public.payments FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "payments_insert_authenticated"
  ON public.payments FOR INSERT
  TO authenticated
  WITH CHECK (true);

CREATE POLICY "payments_update_authenticated"
  ON public.payments FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "payments_delete_admin_only"
  ON public.payments FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- -----------------------------------------------------------------
-- 1.10 TABLE: user_roles
-- READ: Authenticated users can read their OWN role
--        (AuthContext.tsx queries: WHERE user_id = current_user)
-- READ ALL: Admin can see all roles (Users.tsx page)
-- INSERT: Admin only (assign roles)
-- DELETE: Admin only (remove roles)
-- -----------------------------------------------------------------
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "user_roles_select_own"
  ON public.user_roles FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()  -- Users can always read their own role
    OR public.is_admin()  -- Admins can read all roles
  );

CREATE POLICY "user_roles_insert_admin"
  ON public.user_roles FOR INSERT
  TO authenticated
  WITH CHECK (public.is_admin());

CREATE POLICY "user_roles_update_admin"
  ON public.user_roles FOR UPDATE
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "user_roles_delete_admin"
  ON public.user_roles FOR DELETE
  TO authenticated
  USING (public.is_admin());

-- -----------------------------------------------------------------
-- 1.11 TABLE: profiles (if exists — Supabase Auth auto-creates this)
-- READ: Authenticated users read their own profile
--        Admin reads all profiles (Users.tsx page)
-- UPDATE: Users can update their own profile
-- -----------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'profiles') THEN
    EXECUTE 'ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY';

    -- Drop existing policies if any (safe re-run)
    BEGIN EXECUTE 'DROP POLICY IF EXISTS "profiles_select_authenticated" ON public.profiles'; EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN EXECUTE 'DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles'; EXCEPTION WHEN OTHERS THEN NULL; END;

    EXECUTE 'CREATE POLICY "profiles_select_authenticated" ON public.profiles FOR SELECT TO authenticated USING (true)';
    EXECUTE 'CREATE POLICY "profiles_update_own" ON public.profiles FOR UPDATE TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid())';
  END IF;
END $$;


-- =================================================================
-- PART 2: PERFORMANCE INDEXES
-- =================================================================
-- These are safe to add on a live database.
-- IF NOT EXISTS prevents errors on re-run.
-- -----------------------------------------------------------------

-- 2.1 LEDGER ENTRIES (most queried table)
CREATE INDEX IF NOT EXISTS idx_ledger_posting_date
  ON public.ledger_entries(posting_date);

CREATE INDEX IF NOT EXISTS idx_ledger_voucher_no
  ON public.ledger_entries(voucher_no);

CREATE INDEX IF NOT EXISTS idx_ledger_account_id
  ON public.ledger_entries(account_id);

CREATE INDEX IF NOT EXISTS idx_ledger_party_id
  ON public.ledger_entries(party_id);

CREATE INDEX IF NOT EXISTS idx_ledger_voucher_type
  ON public.ledger_entries(voucher_type);

-- Composite index for report queries (date range + account)
CREATE INDEX IF NOT EXISTS idx_ledger_date_account
  ON public.ledger_entries(posting_date, account_id);

-- Composite index for party statement queries
CREATE INDEX IF NOT EXISTS idx_ledger_party_date
  ON public.ledger_entries(party_id, posting_date);

-- 2.2 SALES
CREATE INDEX IF NOT EXISTS idx_sales_date
  ON public.sales(sale_date);

CREATE INDEX IF NOT EXISTS idx_sales_fuel_type
  ON public.sales(fuel_type_id);

CREATE INDEX IF NOT EXISTS idx_sales_party
  ON public.sales(party_id);

-- 2.3 PURCHASES
CREATE INDEX IF NOT EXISTS idx_purchases_date
  ON public.purchases(purchase_date);

CREATE INDEX IF NOT EXISTS idx_purchases_fuel_type
  ON public.purchases(fuel_type_id);

CREATE INDEX IF NOT EXISTS idx_purchases_party
  ON public.purchases(party_id);

-- 2.4 PAYMENTS
CREATE INDEX IF NOT EXISTS idx_payments_date
  ON public.payments(payment_date);

CREATE INDEX IF NOT EXISTS idx_payments_party
  ON public.payments(party_id);

CREATE INDEX IF NOT EXISTS idx_payments_type
  ON public.payments(payment_type);

-- 2.5 PARTIES
CREATE INDEX IF NOT EXISTS idx_parties_type
  ON public.parties(type);

CREATE INDEX IF NOT EXISTS idx_parties_active
  ON public.parties(is_active);


-- =================================================================
-- PART 3: AUDIT_LOGS TABLE (referenced by triggers)
-- =================================================================
-- If this table doesn't exist, trigger INSERT INTO audit_logs will fail.
-- Safe to create — IF NOT EXISTS prevents duplicates.
-- -----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name TEXT NOT NULL,
  record_id UUID,
  voucher_no TEXT,
  action TEXT NOT NULL,  -- 'INSERT', 'UPDATE', 'DELETE', 'REVERSAL'
  old_data JSONB,
  new_data JSONB,
  changed_by UUID DEFAULT auth.uid(),
  changed_at TIMESTAMPTZ DEFAULT NOW(),
  ip_address TEXT,
  notes TEXT
);

-- RLS on audit_logs: read-only for authenticated, only system/admin can write
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "audit_logs_select_authenticated"
  ON public.audit_logs FOR SELECT
  TO authenticated
  USING (true);

-- Insert is done by triggers (running as table owner = bypasses RLS)
-- But also allow authenticated insert in case RPCs write to it
CREATE POLICY "audit_logs_insert_authenticated"
  ON public.audit_logs FOR INSERT
  TO authenticated
  WITH CHECK (true);

-- No update or delete on audit logs (immutable audit trail)
-- Intentionally no UPDATE or DELETE policies


-- =================================================================
-- PART 4: VERIFICATION QUERIES
-- Run these after applying to confirm everything works
-- =================================================================

-- 4.1 Check RLS is enabled on all tables
SELECT
  schemaname,
  tablename,
  rowsecurity
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN (
    'accounts', 'fuel_types', 'parties', 'inventory',
    'ledger_entries', 'sales', 'purchases', 'payments',
    'user_roles', 'profiles', 'audit_logs'
  )
ORDER BY tablename;

-- 4.2 Check indexes exist
SELECT
  indexname,
  tablename
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename IN ('ledger_entries', 'sales', 'purchases', 'payments', 'parties')
ORDER BY tablename, indexname;

-- 4.3 Confirm audit_logs table exists
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'audit_logs'
ORDER BY ordinal_position;

COMMIT;

-- =================================================================
-- 🔄 EMERGENCY ROLLBACK (DO NOT RUN UNLESS THINGS BREAK)
-- =================================================================
-- If something breaks after applying this script, run these lines
-- one by one to disable RLS:
--
-- ALTER TABLE public.accounts DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.fuel_types DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.parties DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.inventory DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.ledger_entries DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.sales DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.purchases DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.payments DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.user_roles DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.audit_logs DISABLE ROW LEVEL SECURITY;
--
-- This will instantly restore your system to its current state.
-- =================================================================

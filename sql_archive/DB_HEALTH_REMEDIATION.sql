-- =================================================================
-- 🛡️ DATABASE HARDENING & PERFORMANCE (LEVEL 2) - FIXED SCHEMA
-- Project: Fuel Trust Ledger (Naveed Musazai Fuel Station)
-- Standards: Munshi-Style Audit Integrity & High-Scale Performance
-- =================================================================

BEGIN;

-- =================================================================
-- 1. PERFORMANCE: COMPOSITE REPORTING INDEXES
-- =================================================================
-- Composite indexes for fast Trial Balance and Ledger generation.

CREATE INDEX IF NOT EXISTS idx_ledger_account_date ON public.ledger_entries (account_id, posting_date);
CREATE INDEX IF NOT EXISTS idx_ledger_party_date ON public.ledger_entries (party_id, posting_date);
CREATE INDEX IF NOT EXISTS idx_ledger_voucher_no ON public.ledger_entries (voucher_no);

CREATE INDEX IF NOT EXISTS idx_sales_reporting ON public.sales (sale_date, party_id);
CREATE INDEX IF NOT EXISTS idx_purchases_reporting ON public.purchases (purchase_date, party_id);
CREATE INDEX IF NOT EXISTS idx_payments_reporting ON public.payments (payment_date, party_id);


-- =================================================================
-- 2. FINANCIAL INTEGRITY: DOUBLE-ENTRY ENFORCEMENT
-- =================================================================

-- Deferred constraint ensures Debit = Credit at COMMIT time.
CREATE OR REPLACE FUNCTION public.enforce_voucher_balance_final()
RETURNS TRIGGER AS $$
DECLARE
    v_diff NUMERIC;
BEGIN
    SELECT ROUND(SUM(debit_amount - credit_amount), 2) INTO v_diff
    FROM public.ledger_entries
    WHERE voucher_no = NEW.voucher_no AND (is_reversed = false OR is_reversed IS NULL);

    IF v_diff IS NOT NULL AND v_diff != 0 THEN
        RAISE EXCEPTION 'ACCOUNTING INTEGRITY FAILURE: Voucher % is unbalanced by %. Action REJECTED.', NEW.voucher_no, v_diff;
    END IF;
    RETURN NULL;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_enforce_balance ON public.ledger_entries;
CREATE CONSTRAINT TRIGGER trg_enforce_balance
AFTER INSERT OR UPDATE ON public.ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.enforce_voucher_balance_final();


-- =================================================================
-- 3. SECURITY: SECURE-BY-DEFAULT RLS
-- =================================================================

-- Ensure RLS is enabled on all tables
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.parties ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_integrity_hashes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- 3.1 FIXED: Admin Check using user_roles table
-- (Replaces old Profiles check which lacked the role column)
DROP POLICY IF EXISTS "Admin Only Access" ON public.ledger_integrity_hashes;
DROP POLICY IF EXISTS "Hashes View" ON public.ledger_integrity_hashes;
DROP POLICY IF EXISTS "Hashes Admin" ON public.ledger_integrity_hashes;
DROP POLICY IF EXISTS "Manage Integrity Hashes" ON public.ledger_integrity_hashes;

CREATE POLICY "Admin Only Access" ON public.ledger_integrity_hashes
    FOR ALL 
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.user_roles 
            WHERE user_id = (SELECT auth.uid()) 
            AND role::TEXT = 'admin'
        )
    );

-- 3.2 Optimization: Standard Profile Access
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile" ON public.profiles 
    FOR SELECT TO authenticated 
    USING (id = (SELECT auth.uid()));


-- =================================================================
-- 4. CLEANUP & PRIVILEGE HARDENING
-- =================================================================
REVOKE ALL ON public.ledger_integrity_hashes FROM anon;
REVOKE ALL ON public.profiles FROM anon;

COMMIT;

-- FINAL HEALTH CHECK
DO $$
BEGIN
    RAISE NOTICE '🚀 PERFORMANCE: Composite reporting indexes deployed.';
    RAISE NOTICE '⚖️ INTEGRITY: Deferred double-entry constraint active.';
    RAISE NOTICE '🔒 SECURITY: RLS strictly enforced; Admin check fixed to use user_roles table.';
    RAISE NOTICE '🎯 Target Scale: 100k - 500k entries (Hardened).';
END $$;

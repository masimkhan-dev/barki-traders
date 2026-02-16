-- =================================================================
-- 🛰️ LEVEL 3: PRODUCTION AUDIT & ACCOUNTABILITY
-- Mission: Zero-Trust Traceability for Financial Transactions
-- Target: Embezzlement Prevention & Audit History
-- =================================================================

BEGIN;

-- 1. IMMUTABLE AUDIT LOG TABLE
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    old_data JSONB,
    new_data JSONB,
    changed_by UUID REFERENCES auth.users(id),
    changed_at TIMESTAMPTZ DEFAULT NOW()
);

-- Optimization Index for Audit History Lookups
CREATE INDEX IF NOT EXISTS idx_audit_logs_record_id ON public.audit_logs (record_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_at ON public.audit_logs (changed_at DESC);

-- 2. SECURE AUDIT LOGGING FUNCTION
CREATE OR REPLACE FUNCTION public.proc_transaction_logger()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO public.audit_logs (table_name, record_id, action, new_data, changed_by)
        VALUES (TG_TABLE_NAME, NEW.id, 'INSERT', to_jsonb(NEW), (SELECT auth.uid()));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO public.audit_logs (table_name, record_id, action, old_data, new_data, changed_by)
        VALUES (TG_TABLE_NAME, NEW.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW), (SELECT auth.uid()));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO public.audit_logs (table_name, record_id, action, old_data, changed_by)
        VALUES (TG_TABLE_NAME, OLD.id, 'DELETE', to_jsonb(OLD), (SELECT auth.uid()));
        RETURN OLD;
    END IF;
    RETURN NULL;
END; $$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. ATTACH AUDIT TRAIL TO CORE BUSINESS TABLES
-- Ledger entries are already hardened by immutability, but sub-ledgers need history.

DROP TRIGGER IF EXISTS trg_audit_sales ON public.sales;
CREATE TRIGGER trg_audit_sales 
AFTER INSERT OR UPDATE OR DELETE ON public.sales 
FOR EACH ROW EXECUTE FUNCTION public.proc_transaction_logger();

DROP TRIGGER IF EXISTS trg_audit_purchases ON public.purchases;
CREATE TRIGGER trg_audit_purchases 
AFTER INSERT OR UPDATE OR DELETE ON public.purchases 
FOR EACH ROW EXECUTE FUNCTION public.proc_transaction_logger();

DROP TRIGGER IF EXISTS trg_audit_payments ON public.payments;
CREATE TRIGGER trg_audit_payments 
AFTER INSERT OR UPDATE OR DELETE ON public.payments 
FOR EACH ROW EXECUTE FUNCTION public.proc_transaction_logger();

-- 4. HARDEN AUDIT LOGS (IMMUTABILITY)
-- Prevent anyone from deleting their track record.
CREATE OR REPLACE FUNCTION public.prevent_audit_tampering()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'COMPLIANCE FAILURE: Audit logs are immutable records and cannot be altered or deleted.';
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_lock_audit_logs ON public.audit_logs;
CREATE TRIGGER trg_lock_audit_logs
BEFORE UPDATE OR DELETE ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_tampering();

-- 5. RLS FOR AUDIT LOGS (Admin Only)
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins can view audit logs" ON public.audit_logs;
CREATE POLICY "Admins can view audit logs" ON public.audit_logs 
FOR SELECT TO authenticated 
USING (
        EXISTS (
            SELECT 1 FROM public.user_roles 
            WHERE user_id = (SELECT auth.uid()) 
            AND role::TEXT = 'admin'
        )
    );

COMMIT;

-- VERIFICATION
DO $$
BEGIN
    RAISE NOTICE '🛰️ Level 3 Deployed: Immutable Audit Trail active for Sales, Purchases, and Payments.';
    RAISE NOTICE '🔒 Security: Audit record deletion/updates are strictly forbidden.';
    RAISE NOTICE '📊 Visibility: Admin dashboard now has access to raw historical changes.';
END $$;

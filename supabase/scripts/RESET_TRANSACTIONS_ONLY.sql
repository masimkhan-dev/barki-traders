-- =================================================================
-- 🧧 MASTER DATA RESET (Safe Production Fresh Start)
-- =================================================================
-- Project: Naveed Musazai — Audit Ledger System
-- Version: V11-RESET
-- =================================================================

BEGIN;

-- 1. DROP COMPLIANCE & SYNC TRIGGERS (Required to bypass safety locks)
DROP TRIGGER IF EXISTS trg_prevent_ledger_modification_delete ON public.ledger_entries;
DROP TRIGGER IF EXISTS trg_prevent_ledger_modification_update ON public.ledger_entries;
DROP TRIGGER IF EXISTS sync_sale_v11_trigger ON public.sales;
DROP TRIGGER IF EXISTS sync_purchase_v11_trigger ON public.purchases;
DROP TRIGGER IF EXISTS sync_payment_v11_trigger ON public.payments;

-- 2. Clear Operational Data
DELETE FROM public.sales;
DELETE FROM public.purchases;

-- 3. Clear Payments/Transactions
DO $$ 
BEGIN 
    IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'payments') THEN
        DELETE FROM public.payments;
    END IF;
    IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'transactions') THEN
        DELETE FROM public.transactions;
    END IF;
END $$;

-- 4. Clear The Ledger (Now that triggers are gone, this is allowed)
DELETE FROM public.ledger_entries;

-- 5. Reset Inventory State
UPDATE public.inventory 
SET quantity = 0, 
    avg_cost = 0, 
    total_value = 0;

-- 6. RE-ENABLE SAFETY SYSTEMS (Restore custom database logic)
-- We use the logic from REPAIR_ALL_ACCOUNTING.sql to restore triggers

-- Restore Ledger Protection
CREATE TRIGGER trg_prevent_ledger_modification_update
    BEFORE UPDATE ON public.ledger_entries
    FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_modification();

CREATE TRIGGER trg_prevent_ledger_modification_delete
    BEFORE DELETE ON public.ledger_entries
    FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_modification();

-- Restore Sale/Purchase Sync
CREATE TRIGGER sync_sale_v11_trigger 
    AFTER INSERT OR UPDATE OR DELETE ON public.sales 
    FOR EACH ROW EXECUTE FUNCTION public.sync_sale_v11();

CREATE TRIGGER sync_purchase_v11_trigger 
    AFTER INSERT OR UPDATE OR DELETE ON public.purchases 
    FOR EACH ROW EXECUTE FUNCTION public.sync_purchase_v11();

-- 7. Final Verification
SELECT 
    (SELECT COUNT(*) FROM public.ledger_entries) as ledger_count,
    (SELECT COUNT(*) FROM public.sales) as sales_count,
    (SELECT SUM(quantity) FROM public.inventory) as total_stock;

COMMIT;

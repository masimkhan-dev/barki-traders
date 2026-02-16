-- =================================================================
-- CONSOLIDATED MASTER MIGRATION - FUEL DEALER MANAGEMENT SYSTEM
-- Version: 1.0 (Production-Ready)
-- Date: 2026-01-26
-- Purpose: Complete system restoration with audit-grade integrity
-- =================================================================
--
-- DEPLOYMENT INSTRUCTIONS:
-- 1. BACKUP your current database before running this migration
-- 2. Run this file in Supabase SQL Editor or via psql
-- 3. Verify execution with: SELECT * FROM pg_tables WHERE schemaname = 'public';
-- 4. Run health check: Execute run_health_check.sql
-- 5. Test: Create purchase → Create sale → Verify stock decreased
--
-- ROLLBACK PLAN:
-- If migration fails, restore from backup:
--   DROP SCHEMA public CASCADE;
--   CREATE SCHEMA public;
--   -- Restore from backup
--
-- =================================================================

BEGIN;

-- =================================================================
-- SECTION 1: CLEANUP (Drop existing business tables)
-- =================================================================

DROP TABLE IF EXISTS public.ledger_entries CASCADE;
DROP TABLE IF EXISTS public.sales CASCADE;
DROP TABLE IF EXISTS public.purchases CASCADE;
DROP TABLE IF EXISTS public.payments CASCADE;
DROP TABLE IF EXISTS public.parties CASCADE;
DROP TABLE IF EXISTS public.accounts CASCADE;
DROP TABLE IF EXISTS public.inventory CASCADE;

-- Drop old sequences if they exist
DROP SEQUENCE IF EXISTS voucher_seq_general CASCADE;
DROP SEQUENCE IF EXISTS voucher_seq_sale CASCADE;
DROP SEQUENCE IF EXISTS voucher_seq_purchase CASCADE;
DROP SEQUENCE IF EXISTS voucher_seq_payment CASCADE;

-- =================================================================
-- SECTION 2: CREATE SEQUENCES (Audit-safe voucher numbering)
-- =================================================================

CREATE SEQUENCE voucher_seq_general START 1000;
CREATE SEQUENCE voucher_seq_sale START 1000;
CREATE SEQUENCE voucher_seq_purchase START 1000;
CREATE SEQUENCE voucher_seq_payment START 1000;

-- =================================================================
-- SECTION 3: CREATE CORE TABLES
-- =================================================================

-- 3.1 ACCOUNTS (Chart of Accounts)
CREATE TABLE public.accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    account_type TEXT NOT NULL CHECK (account_type IN ('asset', 'liability', 'equity', 'income', 'expense')),
    slug TEXT UNIQUE,
    parent_id UUID REFERENCES public.accounts(id) ON DELETE RESTRICT,
    is_system BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_accounts_code ON public.accounts(code);
CREATE INDEX idx_accounts_slug ON public.accounts(slug);
CREATE INDEX idx_accounts_type ON public.accounts(account_type);

-- 3.2 PARTIES (Unified customers/suppliers)
CREATE TABLE public.parties (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('customer', 'supplier', 'both', 'other')),
    phone TEXT,
    address TEXT,
    opening_balance NUMERIC DEFAULT 0,
    current_balance NUMERIC DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id)
);

CREATE INDEX idx_parties_type ON public.parties(type);
CREATE INDEX idx_parties_active ON public.parties(is_active);

-- 3.3 INVENTORY (Stock tracking with weighted average cost)
CREATE TABLE public.inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fuel_type_id UUID NOT NULL REFERENCES public.fuel_types(id) ON DELETE RESTRICT,
    quantity NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    avg_cost NUMERIC(15, 2) NOT NULL DEFAULT 0,
    last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(fuel_type_id)
);

CREATE INDEX idx_inventory_fuel_type ON public.inventory(fuel_type_id);

-- 3.4 LEDGER ENTRIES (General Ledger - Immutable)
CREATE TABLE public.ledger_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL,
    voucher_type TEXT NOT NULL,
    posting_date DATE NOT NULL,
    account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
    party_id UUID REFERENCES public.parties(id) ON DELETE RESTRICT,
    debit_amount NUMERIC NOT NULL DEFAULT 0 CHECK (debit_amount >= 0),
    credit_amount NUMERIC NOT NULL DEFAULT 0 CHECK (credit_amount >= 0),
    narration TEXT,
    is_reversed BOOLEAN DEFAULT false,
    reversal_of UUID REFERENCES public.ledger_entries(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id),
    -- CRITICAL: Enforce single-sided entry (debit OR credit, not both, not neither)
    CONSTRAINT check_single_side_entry CHECK (
        (debit_amount > 0 AND credit_amount = 0) OR 
        (credit_amount > 0 AND debit_amount = 0)
    )
);

CREATE INDEX idx_ledger_voucher ON public.ledger_entries(voucher_no);
CREATE INDEX idx_ledger_account ON public.ledger_entries(account_id);
CREATE INDEX idx_ledger_party ON public.ledger_entries(party_id);
CREATE INDEX idx_ledger_date ON public.ledger_entries(posting_date);
CREATE INDEX idx_ledger_reversed ON public.ledger_entries(is_reversed);

-- 3.5 SALES (Sub-ledger)
CREATE TABLE public.sales (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL UNIQUE,
    sale_date DATE NOT NULL DEFAULT CURRENT_DATE,
    party_id UUID REFERENCES public.parties(id) ON DELETE RESTRICT,
    fuel_type_id UUID,
    quantity NUMERIC NOT NULL CHECK (quantity > 0),
    rate_per_unit NUMERIC NOT NULL CHECK (rate_per_unit > 0),
    total_amount NUMERIC NOT NULL CHECK (total_amount > 0),
    is_credit BOOLEAN DEFAULT false,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id)
);

CREATE INDEX idx_sales_date ON public.sales(sale_date);
CREATE INDEX idx_sales_party ON public.sales(party_id);
CREATE INDEX idx_sales_voucher ON public.sales(voucher_no);

-- 3.6 PURCHASES (Sub-ledger)
CREATE TABLE public.purchases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL UNIQUE,
    purchase_date DATE NOT NULL DEFAULT CURRENT_DATE,
    party_id UUID REFERENCES public.parties(id) ON DELETE RESTRICT,
    fuel_type_id UUID,
    quantity NUMERIC NOT NULL CHECK (quantity > 0),
    rate_per_unit NUMERIC NOT NULL CHECK (rate_per_unit > 0),
    total_amount NUMERIC NOT NULL CHECK (total_amount > 0),
    is_paid_now BOOLEAN DEFAULT false,
    payment_method TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id)
);

CREATE INDEX idx_purchases_date ON public.purchases(purchase_date);
CREATE INDEX idx_purchases_party ON public.purchases(party_id);
CREATE INDEX idx_purchases_voucher ON public.purchases(voucher_no);

-- 3.7 PAYMENTS (Sub-ledger for receipts and payments)
CREATE TABLE public.payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL UNIQUE,
    payment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    payment_type TEXT NOT NULL CHECK (payment_type IN ('receipt', 'payment')),
    party_id UUID REFERENCES public.parties(id) ON DELETE RESTRICT,
    amount NUMERIC NOT NULL CHECK (amount > 0),
    method TEXT DEFAULT 'Cash',
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id)
);

CREATE INDEX idx_payments_date ON public.payments(payment_date);
CREATE INDEX idx_payments_party ON public.payments(party_id);
CREATE INDEX idx_payments_type ON public.payments(payment_type);
CREATE INDEX idx_payments_voucher ON public.payments(voucher_no);

-- =================================================================
-- SECTION 4: SEED CRITICAL ACCOUNTS
-- =================================================================

-- Root accounts
INSERT INTO public.accounts (code, name, account_type, slug, is_system) VALUES
    ('1000', 'Assets', 'asset', 'assets_root', true),
    ('2000', 'Liabilities', 'liability', 'liabilities_root', true),
    ('3000', 'Income', 'income', 'income_root', true),
    ('4000', 'Expenses', 'expense', 'expense_root', true),
    ('5000', 'Equity', 'equity', 'equity_root', true);

-- Leaf accounts (critical for operations)
INSERT INTO public.accounts (code, name, account_type, slug, parent_id, is_system)
SELECT '1010', 'Cash on Hand', 'asset', 'cash', id, true FROM public.accounts WHERE code = '1000'
UNION ALL
SELECT '1100', 'Accounts Receivable', 'asset', 'ar', id, true FROM public.accounts WHERE code = '1000'
UNION ALL
SELECT '1200', 'Inventory', 'asset', 'inventory', id, true FROM public.accounts WHERE code = '1000'
UNION ALL
SELECT '2100', 'Accounts Payable', 'liability', 'ap', id, true FROM public.accounts WHERE code = '2000'
UNION ALL
SELECT '3100', 'Sales Revenue', 'income', 'sales_revenue', id, true FROM public.accounts WHERE code = '3000'
UNION ALL
SELECT '4100', 'Cost of Goods Sold', 'expense', 'cogs', id, true FROM public.accounts WHERE code = '4000';

-- Verify critical accounts exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.accounts WHERE code IN ('1010', '1100', '1200', '2100', '3100', '4100')) THEN
        RAISE EXCEPTION 'CRITICAL: Required control accounts missing';
    END IF;
END $$;

-- Initialize inventory for existing fuel types
INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost)
SELECT id, 0, 0 FROM public.fuel_types
ON CONFLICT (fuel_type_id) DO NOTHING;

-- =================================================================
-- SECTION 5: BUSINESS LOGIC TRIGGERS
-- =================================================================

-- 5.1 PURCHASE TRIGGER: Stock Increase + Ledger Posting
CREATE OR REPLACE FUNCTION public.update_inventory_on_purchase()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    current_qty NUMERIC;
    current_avg_cost NUMERIC;
    new_avg_cost NUMERIC;
    v_inventory_acct UUID;
    v_ap_acct UUID;
BEGIN
    -- Get current inventory state
    SELECT quantity, avg_cost INTO current_qty, current_avg_cost 
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
    
    IF NOT FOUND THEN
        current_qty := 0;
        current_avg_cost := 0;
    END IF;

    -- Calculate new weighted average cost
    IF (current_qty + NEW.quantity) > 0 THEN
        new_avg_cost := ((current_qty * current_avg_cost) + (NEW.quantity * NEW.rate_per_unit)) / (current_qty + NEW.quantity);
    ELSE
        new_avg_cost := NEW.rate_per_unit;
    END IF;

    -- Update inventory
    INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
    VALUES (NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit, NOW())
    ON CONFLICT (fuel_type_id) DO UPDATE
    SET quantity = inventory.quantity + NEW.quantity,
        avg_cost = new_avg_cost,
        last_updated = NOW();

    -- Post to ledger: Dr Inventory, Cr AP
    SELECT id INTO v_inventory_acct FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap_acct FROM public.accounts WHERE slug = 'ap';
    
    IF v_inventory_acct IS NULL OR v_ap_acct IS NULL THEN
        RAISE EXCEPTION 'CRITICAL: Inventory or AP account missing';
    END IF;

    INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, party_id, 
        debit_amount, credit_amount, narration, created_by
    )
    VALUES 
        (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_acct, NULL, 
         NEW.total_amount, 0, 'Inventory Purchase', NEW.created_by),
        (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_acct, NEW.party_id, 
         0, NEW.total_amount, 'Purchase from Supplier', NEW.created_by);

    RETURN NEW;
END;
$$;

CREATE TRIGGER on_purchase_update_inventory
    AFTER INSERT ON public.purchases
    FOR EACH ROW
    EXECUTE FUNCTION public.update_inventory_on_purchase();

-- 5.2 SALE TRIGGER: Stock Decrease + Revenue + COGS Posting
CREATE OR REPLACE FUNCTION public.auto_post_sale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ar_id UUID;
    v_revenue_id UUID;
    v_cash_id UUID;
    v_inventory_id UUID;
    v_cogs_id UUID;
    v_current_stock NUMERIC;
    v_avg_cost NUMERIC;
    v_cogs_amount NUMERIC;
BEGIN
    -- CRITICAL: Lock party row to prevent race conditions
    IF NEW.party_id IS NOT NULL THEN
        PERFORM 1 FROM public.parties WHERE id = NEW.party_id FOR UPDATE;
    END IF;
    
    -- Get account IDs
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_revenue_id FROM public.accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_cash_id FROM public.accounts WHERE slug = 'cash';
    SELECT id INTO v_inventory_id FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM public.accounts WHERE slug = 'cogs';
    
    IF v_ar_id IS NULL OR v_revenue_id IS NULL OR v_cash_id IS NULL OR v_inventory_id IS NULL OR v_cogs_id IS NULL THEN
        RAISE EXCEPTION 'CRITICAL: Control accounts missing for sale posting';
    END IF;

    -- STOCK VALIDATION (Database-level enforcement)
    SELECT quantity, avg_cost INTO v_current_stock, v_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
    
    IF v_current_stock IS NULL THEN
        RAISE EXCEPTION 'STOCK ERROR: Fuel type not found in inventory';
    END IF;
    
    IF v_current_stock < NEW.quantity THEN
        RAISE EXCEPTION 'STOCK ERROR: Insufficient stock. Available: %, Requested: %', v_current_stock, NEW.quantity;
    END IF;

    -- Calculate COGS
    v_cogs_amount := NEW.quantity * v_avg_cost;

    -- Update inventory (decrease stock)
    UPDATE public.inventory
    SET quantity = quantity - NEW.quantity,
        last_updated = NOW()
    WHERE fuel_type_id = NEW.fuel_type_id;
    
    -- Post to ledger based on credit/cash sale
    IF NEW.is_credit THEN
        -- Credit Sale: Dr AR, Cr Revenue
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id, NEW.total_amount, 0, 'Credit Sale - AR', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Credit Sale - Revenue', NEW.created_by);
    ELSE
        -- Cash Sale: Dr Cash, Cr Revenue
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_cash_id, NULL, NEW.total_amount, 0, 'Cash Sale', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Cash Sale - Revenue', NEW.created_by);
    END IF;

    -- COGS Entry: Dr COGS, Cr Inventory
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES 
        (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL, v_cogs_amount, 0, 'Cost of Goods Sold', NEW.created_by),
        (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_id, NULL, 0, v_cogs_amount, 'Inventory Reduction', NEW.created_by);
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_auto_post_sale
    AFTER INSERT ON public.sales
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_post_sale();

-- 5.3 PAYMENT TRIGGER: Auto-post receipts/payments to ledger
CREATE OR REPLACE FUNCTION public.auto_post_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_cash_id UUID;
    v_ar_id UUID;
    v_ap_id UUID;
BEGIN
    -- CRITICAL: Lock party row to prevent race conditions
    IF NEW.party_id IS NOT NULL THEN
        PERFORM 1 FROM public.parties WHERE id = NEW.party_id FOR UPDATE;
    END IF;
    
    SELECT id INTO v_cash_id FROM public.accounts WHERE slug = 'cash';
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
    
    IF v_cash_id IS NULL OR v_ar_id IS NULL OR v_ap_id IS NULL THEN
        RAISE EXCEPTION 'CRITICAL: Control accounts missing for payment posting';
    END IF;
    
    IF NEW.payment_type = 'receipt' THEN
        -- Receipt: Dr Cash, Cr AR
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'receipt', NEW.payment_date, v_cash_id, NULL, NEW.amount, 0, 'Cash Receipt', NEW.created_by),
            (NEW.voucher_no, 'receipt', NEW.payment_date, v_ar_id, NEW.party_id, 0, NEW.amount, 'Receipt from Customer', NEW.created_by);
    ELSE
        -- Payment: Dr AP, Cr Cash
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'payment', NEW.payment_date, v_ap_id, NEW.party_id, NEW.amount, 0, 'Payment to Supplier', NEW.created_by),
            (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, 0, NEW.amount, 'Cash Payment', NEW.created_by);
    END IF;
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_auto_post_payment
    AFTER INSERT ON public.payments
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_post_payment();

-- =================================================================
-- SECTION 6: AUDIT & INTEGRITY ENFORCEMENT
-- =================================================================

-- 6.1 DOUBLE-ENTRY VALIDATION (Deferred Constraint)
CREATE OR REPLACE FUNCTION public.validate_voucher_balance_deferred()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_debit NUMERIC;
    v_credit NUMERIC;
BEGIN
    SELECT
        COALESCE(SUM(debit_amount), 0),
        COALESCE(SUM(credit_amount), 0)
    INTO v_debit, v_credit
    FROM public.ledger_entries
    WHERE voucher_no = NEW.voucher_no
      AND COALESCE(is_reversed, false) = false;

    IF ROUND(v_debit, 2) <> ROUND(v_credit, 2) THEN
        RAISE EXCEPTION
            'DOUBLE-ENTRY VIOLATION: Voucher % is unbalanced at COMMIT. Debit: %, Credit: %. Transaction REJECTED.',
            NEW.voucher_no, v_debit, v_credit
            USING HINT = 'Every voucher must have equal debits and credits';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER enforce_voucher_balance
    AFTER INSERT OR UPDATE ON public.ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_voucher_balance_deferred();

-- 6.2 SOURCE DOCUMENT VALIDATION
CREATE OR REPLACE FUNCTION public.ensure_source_document_exists()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- WHITELIST: Only allow explicitly defined voucher types
    IF NEW.voucher_type NOT IN (
        'sale',
        'purchase',
        'receipt',
        'payment',
        'opening_balance'
    ) THEN
        RAISE EXCEPTION 
            'INVALID VOUCHER TYPE: "%" is not permitted.',
            NEW.voucher_type
            USING HINT = 'Contact system administrator to add new voucher types';
    END IF;

    IF NEW.voucher_type = 'sale' THEN
        IF NOT EXISTS (SELECT 1 FROM public.sales WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 
                'LEDGER INTEGRITY VIOLATION: Sale source document missing for voucher %.',
                NEW.voucher_no;
        END IF;
    END IF;

    IF NEW.voucher_type IN ('receipt', 'payment') THEN
        IF NOT EXISTS (SELECT 1 FROM public.payments WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 
                'LEDGER INTEGRITY VIOLATION: Payment source document missing for voucher %.',
                NEW.voucher_no;
        END IF;
    END IF;

    IF NEW.voucher_type = 'purchase' THEN
        IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 
                'LEDGER INTEGRITY VIOLATION: Purchase source document missing for voucher %.',
                NEW.voucher_no;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER validate_ledger_source
    BEFORE INSERT ON public.ledger_entries
    FOR EACH ROW
    EXECUTE FUNCTION public.ensure_source_document_exists();

-- 6.3 IMMUTABILITY ENFORCEMENT (Ledger)
CREATE OR REPLACE FUNCTION public.prevent_ledger_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Ledger entries are immutable. Use reversal entries for corrections.';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Ledger entries cannot be deleted. Use reversal entries for corrections.';
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trigger_prevent_ledger_update
    BEFORE UPDATE ON public.ledger_entries
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_ledger_modification();

CREATE TRIGGER trigger_prevent_ledger_delete
    BEFORE DELETE ON public.ledger_entries
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_ledger_modification();

-- 6.4 IMMUTABILITY ENFORCEMENT (Sub-Ledgers)
CREATE OR REPLACE FUNCTION public.prevent_subledger_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 
            'Sub-ledger records are immutable. To correct errors, reverse the original transaction and create a new one.';
    END IF;
    
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 
            'Sub-ledger records cannot be deleted. To correct errors, create reversal entries.';
    END IF;
    
    RETURN NULL;
END;
$$;

CREATE TRIGGER prevent_sales_update
    BEFORE UPDATE ON public.sales
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_subledger_modification();

CREATE TRIGGER prevent_sales_delete
    BEFORE DELETE ON public.sales
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_subledger_modification();

CREATE TRIGGER prevent_purchases_update
    BEFORE UPDATE ON public.purchases
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_subledger_modification();

CREATE TRIGGER prevent_purchases_delete
    BEFORE DELETE ON public.purchases
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_subledger_modification();

CREATE TRIGGER prevent_payments_update
    BEFORE UPDATE ON public.payments
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_subledger_modification();

CREATE TRIGGER prevent_payments_delete
    BEFORE DELETE ON public.payments
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_subledger_modification();

-- =================================================================
-- SECTION 7: HELPER FUNCTIONS
-- =================================================================

-- 7.1 Calculate party balance from ledger
CREATE OR REPLACE FUNCTION public.recalculate_party_balance(p_party_id UUID)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_balance NUMERIC;
    v_ar_id UUID;
    v_ap_id UUID;
BEGIN
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
    
    SELECT COALESCE(SUM(
        CASE 
            WHEN le.account_id = v_ar_id THEN le.debit_amount - le.credit_amount
            WHEN le.account_id = v_ap_id THEN le.credit_amount - le.debit_amount
            ELSE 0
        END
    ), 0)
    INTO v_balance
    FROM public.ledger_entries le
    WHERE le.party_id = p_party_id
      AND COALESCE(le.is_reversed, false) = false;
    
    RETURN v_balance;
END;
$$;

-- 7.2 Get party statement
CREATE OR REPLACE FUNCTION public.get_party_statement(p_party_id UUID)
RETURNS TABLE (
    posting_date DATE,
    voucher_no TEXT,
    narration TEXT,
    debit NUMERIC,
    credit NUMERIC,
    balance NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        le.posting_date,
        le.voucher_no,
        le.narration,
        le.debit_amount as debit,
        le.credit_amount as credit,
        SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at) as balance
    FROM public.ledger_entries le
    WHERE le.party_id = p_party_id
      AND COALESCE(le.is_reversed, false) = false
    ORDER BY le.posting_date, le.created_at;
END;
$$;

-- =================================================================
-- SECTION 8: ROW LEVEL SECURITY
-- =================================================================

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.parties ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable all for authenticated users" ON public.accounts FOR ALL TO authenticated USING (true);
CREATE POLICY "Enable all for authenticated users" ON public.parties FOR ALL TO authenticated USING (true);
CREATE POLICY "Enable read for authenticated users" ON public.ledger_entries FOR SELECT TO authenticated USING (true);
CREATE POLICY "Enable insert for authenticated users" ON public.ledger_entries FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Enable all for authenticated users" ON public.sales FOR ALL TO authenticated USING (true);
CREATE POLICY "Enable all for authenticated users" ON public.purchases FOR ALL TO authenticated USING (true);
CREATE POLICY "Enable all for authenticated users" ON public.payments FOR ALL TO authenticated USING (true);
CREATE POLICY "Enable read for authenticated users" ON public.inventory FOR SELECT TO authenticated USING (true);

-- =================================================================
-- SECTION 9: FINAL VALIDATION
-- =================================================================

DO $$
DECLARE
    v_account_count INT;
    v_critical_accounts INT;
    v_trigger_count INT;
BEGIN
    SELECT COUNT(*) INTO v_account_count FROM public.accounts;
    SELECT COUNT(*) INTO v_critical_accounts FROM public.accounts WHERE code IN ('1010', '1100', '1200', '2100', '3100', '4100');
    
    IF v_account_count < 5 THEN
        RAISE EXCEPTION 'VALIDATION FAILED: Insufficient accounts created';
    END IF;
    
    IF v_critical_accounts < 6 THEN
        RAISE EXCEPTION 'VALIDATION FAILED: Critical control accounts missing';
    END IF;
    
    -- Verify triggers exist
    SELECT COUNT(*) INTO v_trigger_count FROM pg_trigger WHERE tgname IN (
        'on_purchase_update_inventory',
        'trigger_auto_post_sale',
        'trigger_auto_post_payment',
        'enforce_voucher_balance',
        'validate_ledger_source',
        'prevent_sales_update',
        'prevent_purchases_update',
        'prevent_payments_update'
    );
    
    IF v_trigger_count < 8 THEN
        RAISE EXCEPTION 'VALIDATION FAILED: Required triggers missing';
    END IF;
    
    RAISE NOTICE '✅ Validation passed: % accounts, % critical accounts, % triggers', v_account_count, v_critical_accounts, v_trigger_count;
END $$;

-- =================================================================
-- COMPLETION
-- =================================================================

DO $$
BEGIN
    RAISE NOTICE '═══════════════════════════════════════════════════════';
    RAISE NOTICE '🎉 MIGRATION COMPLETE';
    RAISE NOTICE '═══════════════════════════════════════════════════════';
    RAISE NOTICE '';
    RAISE NOTICE '✅ System Status: PRODUCTION-READY';
    RAISE NOTICE '✅ Inventory: ACTIVE (with stock validation)';
    RAISE NOTICE '✅ Double-Entry: ENFORCED (deferred constraint)';
    RAISE NOTICE '✅ Immutability: ENFORCED (ledger + sub-ledgers)';
    RAISE NOTICE '✅ Source Validation: ACTIVE';
    RAISE NOTICE '✅ Concurrency: PROTECTED (row locking)';
    RAISE NOTICE '';
    RAISE NOTICE 'Next Steps:';
    RAISE NOTICE '1. Run health check: Execute run_health_check.sql';
    RAISE NOTICE '2. Test purchase → sale flow';
    RAISE NOTICE '3. Verify stock decreases correctly';
    RAISE NOTICE '4. Check ledger balances';
    RAISE NOTICE '═══════════════════════════════════════════════════════';
END $$;

COMMIT;

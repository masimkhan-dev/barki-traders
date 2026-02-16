-- =================================================================
-- 🏆 MASTER BASELINE V11: THE GOLDEN MIGRATION (FINAL)
-- Project: Antigravity - Fuel Trust Ledger (Naveed Musazai Fuel Station)
-- Version: 11.9 (Production Final - Function Drop Fixed)
-- Date: 2026-02-13
-- Logic: Munshi Style (High Integrity, Double Entry)
-- =================================================================

BEGIN;

-- =================================================================
-- 1. NUCLEAR RESET (Sare Purane Functions aur Tables Khatam)
-- =================================================================

-- 1.1 Drop Functions (Correct Signatures ke saath)
DROP FUNCTION IF EXISTS public.get_profit_loss(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_trial_balance(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_trial_balance_v2(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_stock_movement(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_payments_report(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_dashboard_feed(INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.get_market_position_report(DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_customer_ledger_statement(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.get_supplier_ledger_statement(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.get_dashboard_v11_3_analytics(DATE) CASCADE;
DROP FUNCTION IF EXISTS public.initialize_party_ledger_v11() CASCADE;
DROP FUNCTION IF EXISTS public.reverse_transaction(TEXT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.get_daily_summary(DATE) CASCADE;
DROP FUNCTION IF EXISTS public.setup_opening_balances(NUMERIC, NUMERIC, DATE) CASCADE;

-- 1.2 Drop Tables (Correct Order)
DROP TABLE IF EXISTS public.ledger_entries CASCADE;
DROP TABLE IF EXISTS public.sales CASCADE;
DROP TABLE IF EXISTS public.purchases CASCADE;
DROP TABLE IF EXISTS public.payments CASCADE;
DROP TABLE IF EXISTS public.parties CASCADE;
DROP TABLE IF EXISTS public.inventory CASCADE;
DROP TABLE IF EXISTS public.fuel_types CASCADE;
DROP TABLE IF EXISTS public.accounts CASCADE;
DROP TABLE IF EXISTS public.user_roles CASCADE;
DROP TABLE IF EXISTS public.audit_logs CASCADE;

-- =================================================================
-- 2. CORE SCHEMA
-- =================================================================

-- 2.1 FUEL TYPES
CREATE TABLE public.fuel_types (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    unit TEXT DEFAULT 'Liters',
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2.2 ACCOUNTS (Chart of Accounts)
CREATE TABLE public.accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    account_type TEXT NOT NULL CHECK (account_type IN ('asset', 'liability', 'equity', 'income', 'expense')),
    slug TEXT UNIQUE,
    sub_category TEXT,
    is_system BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2.3 PARTIES (Customers/Suppliers)
CREATE TABLE public.parties (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('customer', 'supplier', 'both')),
    phone TEXT,
    address TEXT,
    opening_balance NUMERIC DEFAULT 0,
    current_balance NUMERIC DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- 2.4 INVENTORY
CREATE TABLE public.inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fuel_type_id UUID NOT NULL REFERENCES public.fuel_types(id) ON DELETE RESTRICT,
    quantity NUMERIC(15, 2) NOT NULL DEFAULT 0,
    avg_cost NUMERIC(15, 2) NOT NULL DEFAULT 0,
    last_updated TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(fuel_type_id)
);

-- 2.5 LEDGER ENTRIES
CREATE TABLE public.ledger_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL,
    voucher_type TEXT NOT NULL,
    posting_date DATE NOT NULL,
    account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
    party_id UUID REFERENCES public.parties(id) ON DELETE RESTRICT,
    debit_amount NUMERIC NOT NULL DEFAULT 0,
    credit_amount NUMERIC NOT NULL DEFAULT 0,
    narration TEXT,
    is_reversed BOOLEAN DEFAULT false,
    reconciliation_status BOOLEAN DEFAULT false,
    reconciled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- 2.6 SUB-LEDGERS
CREATE TABLE public.sales (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL UNIQUE,
    sale_date DATE NOT NULL DEFAULT CURRENT_DATE,
    party_id UUID REFERENCES public.parties(id),
    fuel_type_id UUID REFERENCES public.fuel_types(id),
    quantity NUMERIC NOT NULL,
    rate_per_unit NUMERIC NOT NULL,
    total_amount NUMERIC NOT NULL,
    is_credit BOOLEAN DEFAULT true,
    notes TEXT,
    is_reversed BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

CREATE TABLE public.purchases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL UNIQUE,
    purchase_date DATE NOT NULL DEFAULT CURRENT_DATE,
    party_id UUID REFERENCES public.parties(id),
    fuel_type_id UUID REFERENCES public.fuel_types(id),
    quantity NUMERIC NOT NULL,
    rate_per_unit NUMERIC NOT NULL,
    total_amount NUMERIC NOT NULL,
    notes TEXT,
    is_reversed BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

CREATE TABLE public.payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL UNIQUE,
    payment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    payment_type TEXT NOT NULL CHECK (payment_type IN ('receipt', 'payment')),
    party_id UUID REFERENCES public.parties(id),
    amount NUMERIC NOT NULL,
    method TEXT DEFAULT 'Cash',
    notes TEXT,
    is_reversed BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID
);

-- =================================================================
-- 3. CORE LOGIC
-- =================================================================

-- 3.1 PERMISSION ENGINE
CREATE OR REPLACE FUNCTION public.check_v11_permission(p_action TEXT)
RETURNS BOOLEAN AS $$
DECLARE v_role TEXT;
BEGIN
    SELECT role INTO v_role FROM public.user_roles WHERE user_id = auth.uid();
    IF p_action = 'DELETE' AND COALESCE(v_role, 'munshi') != 'admin' THEN
        RAISE EXCEPTION 'PERMISSION DENIED: Only Admin can delete records. Munshi must use reversals.';
    END IF;
    RETURN TRUE;
END; $$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3.2 DASHBOARD ANALYTICS
CREATE OR REPLACE FUNCTION public.get_dashboard_v11_3_analytics(p_date DATE)
RETURNS TABLE (sales_monthly NUMERIC, purchases_monthly NUMERIC, receivables NUMERIC, payables NUMERIC, market_balance NUMERIC) AS $$
DECLARE v_month_start DATE := date_trunc('month', p_date);
BEGIN
    RETURN QUERY 
    WITH PartyBalances AS (
        SELECT p.id, (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) as balance
        FROM public.parties p
        LEFT JOIN public.ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date AND (le.is_reversed = false OR le.is_reversed IS NULL)
        GROUP BY p.id, p.opening_balance
    )
    SELECT 
        (SELECT COALESCE(SUM(total_amount), 0) FROM public.sales WHERE sale_date >= v_month_start AND sale_date <= p_date AND is_reversed = false),
        (SELECT COALESCE(SUM(total_amount), 0) FROM public.purchases WHERE purchase_date >= v_month_start AND purchase_date <= p_date AND is_reversed = false),
        (SELECT COALESCE(SUM(balance), 0) FROM PartyBalances WHERE balance > 0),
        (SELECT ABS(COALESCE(SUM(balance), 0)) FROM PartyBalances WHERE balance < 0),
        (SELECT COALESCE(SUM(balance), 0) FROM PartyBalances);
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 3.3 PARTY SOLIDIFIER
CREATE OR REPLACE FUNCTION public.initialize_party_ledger_v11() RETURNS json AS $$
DECLARE 
    v_party RECORD; v_ar_id UUID; v_ap_id UUID; v_cap_id UUID; v_count INT := 0;
BEGIN
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';
    SELECT id INTO v_cap_id FROM accounts WHERE slug = 'capital';
    FOR v_party IN SELECT id, name, opening_balance FROM parties WHERE opening_balance != 0 LOOP
        IF v_party.opening_balance > 0 THEN
            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
            VALUES ('OPEN-PARTY', 'opening', CURRENT_DATE, v_ar_id, v_party.id, v_party.opening_balance, 0, 'Opening Balance Solidification'),
                   ('OPEN-PARTY', 'opening', CURRENT_DATE, v_cap_id, NULL, 0, v_party.opening_balance, 'Equity Offset: ' || v_party.name);
        ELSE
            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
            VALUES ('OPEN-PARTY', 'opening', CURRENT_DATE, v_ap_id, v_party.id, 0, ABS(v_party.opening_balance), 'Opening Balance Solidification'),
                   ('OPEN-PARTY', 'opening', CURRENT_DATE, v_cap_id, NULL, ABS(v_party.opening_balance), 0, 'Equity Offset: ' || v_party.name);
        END IF;
        UPDATE parties SET opening_balance = 0 WHERE id = v_party.id;
        v_count := v_count + 1;
    END LOOP;
    RETURN json_build_object('success', true, 'parties_solidified', v_count);
END; $$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3.4 TRIAL BALANCE
CREATE OR REPLACE FUNCTION public.get_trial_balance_v2(p_start_date DATE DEFAULT NULL, p_end_date DATE DEFAULT NULL)
RETURNS TABLE (account_code TEXT, account_name TEXT, account_type TEXT, opening_balance NUMERIC, debit_total NUMERIC, credit_total NUMERIC, debit_balance NUMERIC, credit_balance NUMERIC) AS $$
BEGIN
    RETURN QUERY
    WITH all_entities AS (
        SELECT a.id, 'account' as type, a.code as ac, a.name as an, a.account_type as at, 0::NUMERIC as ob FROM public.accounts a WHERE a.slug NOT IN ('ar', 'ap')
        UNION ALL
        SELECT p.id, 'party' as type, (CASE WHEN p.type='customer' THEN '1100-' ELSE '2100-' END || LEFT(p.id::text, 8)) as ac, p.name as an, (CASE WHEN p.type='customer' THEN 'asset' ELSE 'liability' END) as at, p.opening_balance as ob FROM public.parties p
    ),
    ledger_sum AS (
        SELECT 
            ae.id, ae.type,
            SUM(CASE WHEN (p_start_date IS NOT NULL AND le.posting_date < p_start_date) THEN le.debit_amount - le.credit_amount ELSE 0 END) as post_op,
            SUM(CASE WHEN (p_start_date IS NULL OR le.posting_date >= p_start_date) AND (p_end_date IS NULL OR le.posting_date <= p_end_date) THEN le.debit_amount ELSE 0 END) as dr,
            SUM(CASE WHEN (p_start_date IS NULL OR le.posting_date >= p_start_date) AND (p_end_date IS NULL OR le.posting_date <= p_end_date) THEN le.credit_amount ELSE 0 END) as cr
        FROM all_entities ae
        LEFT JOIN public.ledger_entries le ON (ae.type = 'account' AND le.account_id = ae.id) OR (ae.type = 'party' AND le.party_id = ae.id)
        WHERE (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY ae.id, ae.type
    ),
    results AS (
        SELECT ae.ac, ae.an, ae.at, (ae.ob + COALESCE(ls.post_op, 0)) as op, COALESCE(ls.dr, 0) as dr, COALESCE(ls.cr, 0) as cr, (ae.ob + COALESCE(ls.post_op, 0) + COALESCE(ls.dr, 0) - COALESCE(ls.cr, 0)) as bal
        FROM all_entities ae
        LEFT JOIN ledger_sum ls ON ae.id = ls.id AND ae.type = ls.type
    )
    SELECT ac, an, at, op, dr, cr, CASE WHEN bal > 0 THEN bal ELSE 0 END, CASE WHEN bal < 0 THEN ABS(bal) ELSE 0 END
    FROM results WHERE dr != 0 OR cr != 0 OR op != 0 ORDER BY ac;
END; $$ LANGUAGE plpgsql STABLE;

-- 3.5 PROFIT & LOSS
CREATE OR REPLACE FUNCTION public.get_profit_loss(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (section TEXT, account_name TEXT, amount NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        CASE 
            WHEN a.account_type = 'income' THEN 'Income'::TEXT
            WHEN a.slug = 'cogs' OR a.code = '4100' THEN 'Direct Costs'::TEXT
            ELSE 'Expenses'::TEXT
        END as section,
        a.name,
        CASE WHEN a.account_type = 'income' THEN SUM(le.credit_amount - le.debit_amount) ELSE SUM(le.debit_amount - le.credit_amount) END
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date BETWEEN p_start_date AND p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name, a.account_type, a.slug, a.code
    HAVING ABS(SUM(le.debit_amount - le.credit_amount)) > 0.01;
END; $$ LANGUAGE plpgsql STABLE;

-- 3.6 REVERSAL ENGINE
CREATE OR REPLACE FUNCTION public.reverse_transaction(p_voucher_no TEXT, p_reason TEXT) RETURNS json AS $$
DECLARE v_new_vno TEXT; v_found BOOLEAN := false;
BEGIN
    v_new_vno := 'REV-' || p_voucher_no;
    IF EXISTS (SELECT 1 FROM sales WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO sales (voucher_no, sale_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, notes, created_by)
        SELECT v_new_vno, CURRENT_DATE, party_id, fuel_type_id, -quantity, rate_per_unit, -total_amount, 'REV: ' || p_reason, auth.uid() FROM sales WHERE voucher_no = p_voucher_no;
        UPDATE sales SET is_reversed = true WHERE voucher_no = p_voucher_no; v_found := true;
    END IF;
    IF NOT v_found AND EXISTS (SELECT 1 FROM purchases WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO purchases (voucher_no, purchase_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, notes, created_by)
        SELECT v_new_vno, CURRENT_DATE, party_id, fuel_type_id, -quantity, rate_per_unit, -total_amount, 'REV: ' || p_reason, auth.uid() FROM purchases WHERE voucher_no = p_voucher_no;
        UPDATE purchases SET is_reversed = true WHERE voucher_no = p_voucher_no; v_found := true;
    END IF;
    IF NOT v_found AND EXISTS (SELECT 1 FROM payments WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO payments (voucher_no, payment_type, payment_date, party_id, amount, method, notes, created_by)
        SELECT v_new_vno, payment_type, CURRENT_DATE, party_id, -amount, method, 'REV: ' || p_reason, auth.uid() FROM payments WHERE voucher_no = p_voucher_no;
        UPDATE payments SET is_reversed = true WHERE voucher_no = p_voucher_no; v_found := true;
    END IF;
    UPDATE ledger_entries SET is_reversed = true WHERE voucher_no = p_voucher_no;
    RETURN json_build_object('success', true, 'reversal_voucher', v_new_vno);
END; $$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3.7 STOCK MOVEMENT
CREATE OR REPLACE FUNCTION public.get_stock_movement(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (fuel_type_id UUID, fuel_name TEXT, opening_stock NUMERIC, purchased NUMERIC, sold NUMERIC, closing_stock NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ft.id, ft.name,
        COALESCE((SELECT i.quantity FROM inventory i WHERE i.fuel_type_id = ft.id), 0) - 
        COALESCE((SELECT SUM(s.quantity) FROM sales s WHERE s.fuel_type_id = ft.id AND s.sale_date >= p_start_date AND is_reversed = false), 0) +
        COALESCE((SELECT SUM(p.quantity) FROM purchases p WHERE p.fuel_type_id = ft.id AND p.purchase_date >= p_start_date AND is_reversed = false), 0),
        COALESCE((SELECT SUM(p.quantity) FROM purchases p WHERE p.fuel_type_id = ft.id AND p.purchase_date BETWEEN p_start_date AND p_end_date AND is_reversed = false), 0),
        COALESCE((SELECT SUM(s.quantity) FROM sales s WHERE s.fuel_type_id = ft.id AND s.sale_date BETWEEN p_start_date AND p_end_date AND is_reversed = false), 0),
        COALESCE((SELECT i.quantity FROM inventory i WHERE i.fuel_type_id = ft.id), 0)
    FROM fuel_types ft WHERE ft.is_active = true;
END; $$ LANGUAGE plpgsql STABLE;

-- 3.8 PAYMENTS REPORT
CREATE OR REPLACE FUNCTION public.get_payments_report(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (posting_date DATE, voucher_no TEXT, voucher_type TEXT, from_name TEXT, to_name TEXT, amount NUMERIC, narration TEXT) AS $$
BEGIN
    RETURN QUERY
    WITH pairs AS (
        SELECT le.voucher_no, le.posting_date, le.voucher_type, le.narration, le.created_at,
               CASE WHEN le.credit_amount > 0 THEN COALESCE(p.name, a.name) END as giver,
               CASE WHEN le.debit_amount > 0 THEN COALESCE(p.name, a.name) END as receiver,
               GREATEST(le.debit_amount, le.credit_amount) as amt
        FROM ledger_entries le JOIN accounts a ON le.account_id = a.id LEFT JOIN parties p ON le.party_id = p.id
        WHERE le.voucher_type IN ('receipt', 'payment', 'transfer', 'munshi_voucher', 'journal') AND (le.is_reversed = false OR le.is_reversed IS NULL)
    )
    SELECT posting_date, voucher_no, voucher_type, MAX(giver) FILTER (WHERE giver IS NOT NULL), MAX(receiver) FILTER (WHERE receiver IS NOT NULL), MAX(amt), MAX(narration)
    FROM pairs WHERE posting_date BETWEEN p_start_date AND p_end_date GROUP BY voucher_no, posting_date, voucher_type, created_at ORDER BY posting_date DESC, created_at DESC;
END; $$ LANGUAGE plpgsql STABLE;

-- =================================================================
-- 4. SMART TRIGGERS
-- =================================================================

CREATE OR REPLACE FUNCTION public.sync_party_balance_v11() RETURNS TRIGGER AS $$
BEGIN
    UPDATE public.parties p 
    SET current_balance = COALESCE(p.opening_balance, 0) + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND (is_reversed = false OR is_reversed IS NULL)), 0)
    WHERE p.id = NEW.party_id OR p.id = OLD.party_id;
    RETURN NULL;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER sync_party_balance_trigger AFTER INSERT OR UPDATE OR DELETE ON public.ledger_entries FOR EACH ROW EXECUTE FUNCTION public.sync_party_balance_v11();

-- SALES SYNC
CREATE OR REPLACE FUNCTION public.sync_sale_v11() RETURNS TRIGGER AS $$
DECLARE v_inv UUID; v_cogs UUID; v_rev UUID; v_ar UUID; v_cost NUMERIC;
BEGIN
    SELECT id INTO v_inv FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs FROM accounts WHERE slug = 'cogs';
    SELECT id INTO v_rev FROM accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_ar FROM accounts WHERE slug = 'ar';
    
    -- Handle OLD data (Delete or Update start)
    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        UPDATE public.inventory SET quantity = quantity + OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    END IF;

    -- Handle NEW data (Insert or Update end)
    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        SELECT COALESCE(avg_cost, 0) INTO v_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
        UPDATE public.inventory SET quantity = quantity - NEW.quantity WHERE fuel_type_id = NEW.fuel_type_id;
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_ar, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale'),
               (NEW.voucher_no, 'sale', NEW.sale_date, v_rev, NULL, 0, NEW.total_amount, 'Sales Revenue'),
               (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs, NULL, (NEW.quantity * v_cost), 0, 'COGS'),
               (NEW.voucher_no, 'sale', NEW.sale_date, v_inv, NULL, 0, (NEW.quantity * v_cost), 'Inventory Credit');
        RETURN NEW;
    END IF;
    
    IF (TG_OP = 'DELETE') THEN RETURN OLD; END IF;
    RETURN NULL;
END; $$ LANGUAGE plpgsql;
CREATE TRIGGER sync_sale_trigger AFTER INSERT OR UPDATE OR DELETE ON public.sales FOR EACH ROW EXECUTE FUNCTION public.sync_sale_v11();

-- PURCHASE SYNC
CREATE OR REPLACE FUNCTION public.sync_purchase_v11() RETURNS TRIGGER AS $$
DECLARE v_inv UUID; v_ap UUID; v_qty NUMERIC; v_cost NUMERIC;
BEGIN
    SELECT id INTO v_inv FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap FROM accounts WHERE slug = 'ap';

    -- Handle OLD data (Delete or Update start)
    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        UPDATE public.inventory SET quantity = quantity - OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    END IF;

    -- Handle NEW data (Insert or Update end)
    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        SELECT quantity, avg_cost INTO v_qty, v_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
        -- Recalculate average cost only on purchase
        IF (v_qty + NEW.quantity) > 0 THEN 
            v_cost := ((v_qty * v_cost) + (NEW.quantity * NEW.rate_per_unit)) / (v_qty + NEW.quantity); 
        END IF;
        
        UPDATE public.inventory SET quantity = quantity + NEW.quantity, avg_cost = v_cost WHERE fuel_type_id = NEW.fuel_type_id;
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv, NULL, NEW.total_amount, 0, 'Purchase'),
               (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap, NEW.party_id, 0, NEW.total_amount, 'Accounts Payable');
        RETURN NEW;
    END IF;

    IF (TG_OP = 'DELETE') THEN RETURN OLD; END IF;
    RETURN NULL;
END; $$ LANGUAGE plpgsql;
CREATE TRIGGER sync_purchase_trigger AFTER INSERT OR UPDATE OR DELETE ON public.purchases FOR EACH ROW EXECUTE FUNCTION public.sync_purchase_v11();

-- =================================================================
-- 5. SEED DATA
-- =================================================================
INSERT INTO public.fuel_types (name) VALUES ('Petrol'), ('Diesel'), ('Hi-Speed');
INSERT INTO public.accounts (code, name, account_type, slug, is_system) VALUES
    ('1000', 'Cash on Hand', 'asset', 'cash', true),
    ('1010', 'Bank Account', 'asset', 'bank', true),
    ('1100', 'Accounts Receivable (Control)', 'asset', 'ar', true),
    ('1200', 'Inventory (Control)', 'asset', 'inventory', true),
    ('2000', 'Accounts Payable (Control)', 'liability', 'ap', true),
    ('3000', 'Owner''s Capital', 'equity', 'capital', true),
    ('4000', 'Sales Revenue', 'income', 'sales_revenue', true),
    ('4100', 'Cost of Goods Sold', 'expense', 'cogs', true),
    ('6000', 'Miscellaneous Expenses', 'expense', 'operating_expenses', true);
INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost) SELECT id, 0, 0 FROM public.fuel_types;

-- =================================================================
-- 6. DASHBOARD FEED & MARKET POSITION
-- =================================================================

CREATE OR REPLACE FUNCTION get_dashboard_feed(p_limit INTEGER DEFAULT 20)
RETURNS TABLE (id UUID, date DATE, voucher_no TEXT, party_name TEXT, description TEXT, paid NUMERIC, received NUMERIC, running_balance NUMERIC) AS $$
BEGIN
    RETURN QUERY SELECT le.id, le.posting_date, le.voucher_no, p.name, le.narration, le.debit_amount, le.credit_amount, 
                        (SELECT COALESCE(SUM(le2.debit_amount - le2.credit_amount), 0) FROM ledger_entries le2 WHERE le2.party_id = le.party_id AND (le2.posting_date < le.posting_date OR (le2.posting_date = le.posting_date AND le2.created_at <= le.created_at))) + COALESCE(p.opening_balance, 0)
    FROM ledger_entries le JOIN parties p ON le.party_id = p.id ORDER BY le.posting_date DESC, le.created_at DESC LIMIT p_limit;
END; $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_market_position_report(p_as_of_date DATE)
RETURNS TABLE (party_id UUID, party_name TEXT, party_type TEXT, receivable_balance NUMERIC, payable_balance NUMERIC, last_transaction_date DATE) AS $$
BEGIN
    RETURN QUERY WITH Balances AS (
        SELECT p.id, p.name, p.type, (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) as bal, MAX(le.posting_date) as last_tx
        FROM parties p LEFT JOIN ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_as_of_date AND (le.is_reversed = false OR le.is_reversed IS NULL)
        GROUP BY p.id, p.name, p.type, p.opening_balance
    ) SELECT id, name, type, CASE WHEN bal > 0 THEN bal ELSE 0 END, CASE WHEN bal < 0 THEN ABS(bal) ELSE 0 END, last_tx FROM Balances WHERE bal != 0;
END; $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION public.get_customer_ledger_statement(target_customer_id UUID)
RETURNS TABLE (entry_id UUID, posting_date DATE, voucher_no TEXT, voucher_type TEXT, narration TEXT, debit_amount NUMERIC, credit_amount NUMERIC, quantity NUMERIC, rate NUMERIC, fuel_type TEXT) AS $$
BEGIN
    RETURN QUERY SELECT id, le.posting_date, le.voucher_no, le.voucher_type, le.narration, le.debit_amount, le.credit_amount, 
                        (SELECT s.quantity FROM sales s WHERE s.voucher_no = le.voucher_no LIMIT 1),
                        (SELECT s.rate_per_unit FROM sales s WHERE s.voucher_no = le.voucher_no LIMIT 1),
                        (SELECT f.name FROM sales s JOIN fuel_types f ON s.fuel_type_id = f.id WHERE s.voucher_no = le.voucher_no LIMIT 1)
    FROM ledger_entries le WHERE le.party_id = target_customer_id AND (le.is_reversed = false OR le.is_reversed IS NULL) ORDER BY le.posting_date, le.created_at;
END; $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION public.get_supplier_ledger_statement(target_supplier_id UUID)
RETURNS TABLE (entry_id UUID, posting_date DATE, voucher_no TEXT, voucher_type TEXT, narration TEXT, debit_amount NUMERIC, credit_amount NUMERIC, quantity NUMERIC, rate NUMERIC, fuel_type TEXT) AS $$
BEGIN
    RETURN QUERY SELECT id, le.posting_date, le.voucher_no, le.voucher_type, le.narration, le.debit_amount, le.credit_amount, 
                        (SELECT pu.quantity FROM purchases pu WHERE pu.voucher_no = le.voucher_no LIMIT 1),
                        (SELECT pu.rate_per_unit FROM purchases pu WHERE pu.voucher_no = le.voucher_no LIMIT 1),
                        (SELECT f.name FROM purchases pu JOIN fuel_types f ON pu.fuel_type_id = f.id WHERE pu.voucher_no = le.voucher_no LIMIT 1)
    FROM ledger_entries le WHERE le.party_id = target_supplier_id AND (le.is_reversed = false OR le.is_reversed IS NULL) ORDER BY le.posting_date, le.created_at;
END; $$ LANGUAGE plpgsql STABLE;

COMMIT;

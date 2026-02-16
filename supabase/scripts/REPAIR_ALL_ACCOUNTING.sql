-- =================================================================
-- FINAL NUCLEAR REPAIR: MASTER ACCOUNTING LOGIC (V11+)
-- Purpose: Fixes "null account_id" errors and enforces granular 
--          permissions: Admin can DELETE, Accountant can only EDIT.
-- =================================================================

BEGIN;

SET search_path = public;

-- STEP 2: DROP OLD FUNCTIONS & TRIGGERS (Required to change parameter names)
DROP TRIGGER IF EXISTS trigger_auto_post_sale ON public.sales;
DROP TRIGGER IF EXISTS sync_sale_trigger ON public.sales;
DROP TRIGGER IF EXISTS sync_sale_v11_trigger ON public.sales;
DROP TRIGGER IF EXISTS trigger_auto_post_purchase ON public.purchases;
DROP TRIGGER IF EXISTS sync_purchase_trigger ON public.purchases;
DROP TRIGGER IF EXISTS sync_purchase_v11_trigger ON public.purchases;
DROP TRIGGER IF EXISTS trigger_auto_post_payment ON public.payments;
DROP TRIGGER IF EXISTS sync_payment_v11_trigger ON public.payments;
DROP TRIGGER IF EXISTS trigger_prevent_ledger_update ON public.ledger_entries;
DROP TRIGGER IF EXISTS trigger_prevent_ledger_delete ON public.ledger_entries;

-- Drop functions explicitly to avoid parameter name conflict errors
DROP FUNCTION IF EXISTS public.auto_post_sale();
DROP FUNCTION IF EXISTS public.sync_sale_v11();
DROP FUNCTION IF EXISTS public.sync_purchase_v11();
DROP FUNCTION IF EXISTS public.sync_payment_v11();
DROP FUNCTION IF EXISTS public.auto_post_payment();
DROP FUNCTION IF EXISTS public.post_expense_entry(uuid,uuid,numeric,text,date);
DROP FUNCTION IF EXISTS public.post_munshi_voucher(uuid,uuid,numeric,text,date);
DROP FUNCTION IF EXISTS public.prevent_ledger_modification();

--------------------------------------------------------------------------------
-- STEP 3: REFINED SALE TRIGGER
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_sale_v11()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE 
    v_inv_id UUID; v_cogs_id UUID; v_rev_id UUID; 
    v_ar_id UUID; v_cash_id UUID;
    v_cost NUMERIC; v_dr_id UUID; 
    v_party_id UUID; v_nar TEXT;
BEGIN
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM accounts WHERE slug = 'cogs';
    SELECT id INTO v_rev_id FROM accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_cash_id FROM accounts WHERE slug = 'cash';

    IF v_inv_id IS NULL OR v_cogs_id IS NULL OR v_rev_id IS NULL 
       OR (v_ar_id IS NULL AND v_cash_id IS NULL) THEN
        RAISE EXCEPTION 'SALE TRIGGER ERROR: Required control accounts missing.';
    END IF;

    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        UPDATE public.inventory SET quantity = quantity + OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    END IF;

    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        IF NEW.is_credit THEN
            v_dr_id := v_ar_id; v_party_id := NEW.party_id; v_nar := 'Fuel Sale (Credit)';
        ELSE
            v_dr_id := v_cash_id; v_party_id := NULL; v_nar := 'Fuel Sale (Cash)';
        END IF;

        IF v_dr_id IS NULL THEN RAISE EXCEPTION 'SALE TRIGGER ERROR: Account resolution failed.'; END IF;

        UPDATE public.inventory SET quantity = quantity - NEW.quantity WHERE fuel_type_id = NEW.fuel_type_id;
        
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_dr_id, v_party_id, NEW.total_amount, 0, v_nar, NEW.created_by),
               (NEW.voucher_no, 'sale', NEW.sale_date, v_rev_id, NULL, 0, NEW.total_amount, 'Sales Revenue', NEW.created_by);
        
        SELECT COALESCE(avg_cost, 0) INTO v_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;

        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL, (NEW.quantity * v_cost), 0, 'COGS: ' || NEW.quantity || ' Units', NEW.created_by),
               (NEW.voucher_no, 'sale', NEW.sale_date, v_inv_id, NULL, 0, (NEW.quantity * v_cost), 'Inventory Reduction', NEW.created_by);
        RETURN NEW;
    END IF;
    RETURN NULL;
END; $$;

CREATE TRIGGER sync_sale_v11_trigger AFTER INSERT OR UPDATE OR DELETE ON public.sales FOR EACH ROW EXECUTE FUNCTION public.sync_sale_v11();

--------------------------------------------------------------------------------
-- STEP 4: REFINED PURCHASE TRIGGER
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_purchase_v11()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_inv_id UUID; v_ap_id UUID; v_qty NUMERIC; v_cost NUMERIC;
BEGIN
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';

    IF v_inv_id IS NULL OR v_ap_id IS NULL THEN RAISE EXCEPTION 'PURCHASE TRIGGER ERROR: accounts missing.'; END IF;

    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        UPDATE public.inventory SET quantity = quantity - OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    END IF;

    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        SELECT quantity, avg_cost INTO v_qty, v_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
        IF (COALESCE(v_qty, 0) + NEW.quantity) > 0 THEN 
            v_cost := ((COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) + (NEW.quantity * NEW.rate_per_unit)) / (COALESCE(v_qty, 0) + NEW.quantity); 
        ELSE v_cost := NEW.rate_per_unit;
        END IF;
        
        UPDATE public.inventory SET quantity = quantity + NEW.quantity, avg_cost = v_cost WHERE fuel_type_id = NEW.fuel_type_id;

        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv_id, NULL, NEW.total_amount, 0, 'Inventory Purchase', NEW.created_by),
               (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id, 0, NEW.total_amount, 'Accounts Payable', NEW.created_by);
        RETURN NEW;
    END IF;
    RETURN NULL;
END; $$;

CREATE TRIGGER sync_purchase_v11_trigger AFTER INSERT OR UPDATE OR DELETE ON public.purchases FOR EACH ROW EXECUTE FUNCTION public.sync_purchase_v11();

--------------------------------------------------------------------------------
-- STEP 5: EXPENSE RPC
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_expense_entry(p_expense_account_id UUID, p_payment_account_id UUID, p_amount NUMERIC, p_narration TEXT, p_date DATE) 
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_voucher_no TEXT; v_seq_num INT;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    SELECT COALESCE(COUNT(*), 0) + 1 INTO v_seq_num FROM ledger_entries WHERE posting_date = p_date AND voucher_no LIKE 'EXP-%';
    v_voucher_no := 'EXP-' || TO_CHAR(p_date, 'YYYYMMDD') || '-' || LPAD(v_seq_num::TEXT, 3, '0');
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'payment', p_date, p_expense_account_id, p_amount, 0, p_narration, auth.uid()),
           (v_voucher_no, 'payment', p_date, p_payment_account_id, 0, p_amount, p_narration, auth.uid());
    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END; $$;

--------------------------------------------------------------------------------
-- STEP 6: TRANSFER RPC
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_munshi_voucher(p_from_id UUID, p_to_id UUID, p_amount NUMERIC, p_narration TEXT, p_date DATE) 
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_voucher_no TEXT; v_dr_acct UUID; v_cr_acct UUID; v_from_is_party BOOLEAN; v_to_is_party BOOLEAN; v_party_type TEXT; v_ar_id UUID; v_ap_id UUID;
BEGIN
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';
    v_voucher_no := 'VCH-' || TO_CHAR(p_date, 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 9999)::TEXT, 4, '0');
    SELECT EXISTS(SELECT 1 FROM parties WHERE id = p_from_id) INTO v_from_is_party;
    IF v_from_is_party THEN SELECT type INTO v_party_type FROM parties WHERE id = p_from_id; v_cr_acct := CASE WHEN v_party_type = 'supplier' THEN v_ap_id ELSE v_ar_id END; ELSE v_cr_acct := p_from_id; END IF;
    SELECT EXISTS(SELECT 1 FROM parties WHERE id = p_to_id) INTO v_to_is_party;
    IF v_to_is_party THEN SELECT type INTO v_party_type FROM parties WHERE id = p_to_id; v_dr_acct := CASE WHEN v_party_type = 'supplier' THEN v_ap_id ELSE v_ar_id END; ELSE v_dr_acct := p_to_id; END IF;
    
    IF v_dr_acct IS NULL OR v_cr_acct IS NULL THEN RAISE EXCEPTION 'TRANSFER ERROR: Control accounts missing.'; END IF;

    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'transfer', p_date, v_dr_acct, CASE WHEN v_to_is_party THEN p_to_id ELSE NULL END, p_amount, 0, p_narration, auth.uid()),
           (v_voucher_no, 'transfer', p_date, v_cr_acct, CASE WHEN v_from_is_party THEN p_from_id ELSE NULL END, 0, p_amount, p_narration, auth.uid());
    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END; $$;

--------------------------------------------------------------------------------
-- STEP 7: LEDGER PROTECTION — GRANULAR PERMISSIONS
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prevent_ledger_modification() 
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_role TEXT;
BEGIN
    SELECT role INTO v_role FROM public.user_roles WHERE user_id = auth.uid();

    -- 1. DELETE: Sirf Admin allowed hai
    IF TG_OP = 'DELETE' THEN
        IF v_role = 'admin' THEN
            RETURN OLD;
        ELSE
            RAISE EXCEPTION 'COMPLIANCE ERROR: Only ADMIN is authorized to delete entries.';
        END IF;
    END IF;

    -- 2. UPDATE: Admin aur Accountant dono allowed hain
    IF TG_OP = 'UPDATE' THEN
        IF v_role IN ('admin', 'accountant') THEN
            RETURN NEW;
        ELSE
            RAISE EXCEPTION 'COMPLIANCE ERROR: You do not have permission to edit ledger entries.';
        END IF;
    END IF;

    RETURN NEW;
END; $$;

-- Apply triggers to ledger_entries
CREATE TRIGGER trg_prevent_ledger_modification_update
    BEFORE UPDATE ON public.ledger_entries
    FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_modification();

CREATE TRIGGER trg_prevent_ledger_modification_delete
    BEFORE DELETE ON public.ledger_entries
    FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_modification();

COMMIT;

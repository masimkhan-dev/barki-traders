-- =================================================================
-- PRODUCTION-GRADE ACCOUNTING & INVENTORY INTEGRITY (V11-GOLD)
-- =================================================================

BEGIN;

SET search_path = public;

--------------------------------------------------------------------------------
-- 1. HARDENED PURCHASE TRIGGER (Average Cost + Race Condition Protection)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_purchase_v11()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE 
    v_inv_id UUID; v_ap_id UUID; 
    v_qty NUMERIC; v_cost NUMERIC;
BEGIN
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';

    -- [A] REVERSAL (Handle Delete/Update)
    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        -- 1. LOCK & CHECK STOCK (Race-condition protection)
        SELECT quantity, avg_cost INTO v_qty, v_cost 
        FROM public.inventory WHERE fuel_type_id = OLD.fuel_type_id FOR UPDATE;

        IF (COALESCE(v_qty, 0) - OLD.quantity + COALESCE(NEW.quantity, 0)) < 0 THEN
            RAISE EXCEPTION 'STOCK INTEGRITY ERROR: Cannot reduce purchase. Current stock (%) is less than reduction quantity (%).', v_qty, OLD.quantity;
        END IF;

        -- 2. Audit Old State
        INSERT INTO audit_logs (table_name, record_id, action, old_data, changed_by)
        VALUES ('purchases', OLD.id, TG_OP, row_to_json(OLD), auth.uid());

        -- 3. Cleanup
        UPDATE public.inventory SET quantity = quantity - OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    END IF;

    -- [B] APPLICATION (Handle Insert/Update)
    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        IF NEW.quantity <= 0 THEN RAISE EXCEPTION 'PURCHASE ERROR: Quantity must be positive.'; END IF;

        -- Recalculate Average Cost
        SELECT quantity, avg_cost INTO v_qty, v_cost 
        FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

        IF (COALESCE(v_qty, 0) + NEW.quantity) > 0 THEN 
            v_cost := ((COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) + (NEW.quantity * NEW.rate_per_unit)) / (COALESCE(v_qty, 0) + NEW.quantity); 
        ELSE v_cost := NEW.rate_per_unit; END IF;
        
        UPDATE public.inventory SET quantity = quantity + NEW.quantity, avg_cost = v_cost WHERE fuel_type_id = NEW.fuel_type_id;

        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv_id, NULL, NEW.total_amount, 0, 'Inventory Purchase', NEW.created_by),
               (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id, 0, NEW.total_amount, 'Accounts Payable', NEW.created_by);
        RETURN NEW;
    END IF;
    RETURN NULL;
END; $$;

--------------------------------------------------------------------------------
-- 2. HARDENED SALE TRIGGER (Revenue + COGS + Stock Check)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_sale_v11()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE 
    v_inv_id UUID; v_cogs_id UUID; v_rev_id UUID; v_ar_id UUID; v_cash_id UUID;
    v_cur_qty NUMERIC; v_cost NUMERIC; v_dr_id UUID; v_nar TEXT;
BEGIN
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM accounts WHERE slug = 'cogs';
    SELECT id INTO v_rev_id FROM accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_cash_id FROM accounts WHERE slug = 'cash';

    -- [A] REVERSAL
    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        UPDATE public.inventory SET quantity = quantity + OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        
        INSERT INTO audit_logs (table_name, record_id, action, old_data, changed_by)
        VALUES ('sales', OLD.id, TG_OP, row_to_json(OLD), auth.uid());
    END IF;

    -- [B] APPLICATION
    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        IF NEW.quantity <= 0 THEN RAISE EXCEPTION 'SALE ERROR: Quantity must be positive.'; END IF;

        -- 1. Check Stock Sufficiency
        SELECT quantity, avg_cost INTO v_cur_qty, v_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;
        IF v_cur_qty < NEW.quantity THEN
            RAISE EXCEPTION 'STOCK OUT: Only % L available. Requested: % L.', v_cur_qty, NEW.quantity;
        END IF;

        IF NEW.is_credit THEN v_dr_id := v_ar_id; v_nar := 'Fuel Sale (Credit)';
        ELSE v_dr_id := v_cash_id; v_nar := 'Fuel Sale (Cash)'; END IF;

        -- 2. Deduct Inventory
        UPDATE public.inventory SET quantity = quantity - NEW.quantity WHERE fuel_type_id = NEW.fuel_type_id;
        
        -- 3. Post Ledger
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_dr_id, CASE WHEN NEW.is_credit THEN NEW.party_id ELSE NULL END, NEW.total_amount, 0, v_nar, NEW.created_by),
               (NEW.voucher_no, 'sale', NEW.sale_date, v_rev_id, NULL, 0, NEW.total_amount, 'Sales Revenue', NEW.created_by),
               (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL, (NEW.quantity * v_cost), 0, 'COGS Adjustment', NEW.created_by),
               (NEW.voucher_no, 'sale', NEW.sale_date, v_inv_id, NULL, 0, (NEW.quantity * v_cost), 'Inventory Reduction', NEW.created_by);
        RETURN NEW;
    END IF;
    RETURN NULL;
END; $$;

COMMIT;

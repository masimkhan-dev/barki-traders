-- FIX: Sale and Purchase Trigger Security
-- Purpose: Adds SECURITY DEFINER to bypass RLS/Permission blocks on account lookups.

BEGIN;

--------------------------------------------------------------------------------
-- 1. PURHCASE TRIGGER
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_purchase_v11()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE v_inv UUID; v_ap UUID; v_qty NUMERIC; v_cost NUMERIC;
BEGIN
    SELECT id INTO v_inv FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap FROM accounts WHERE slug = 'ap';

    IF v_inv IS NULL OR v_ap IS NULL THEN
        RAISE EXCEPTION 'PURCHASE TRIGGER ERROR: System accounts (inventory or ap) missing or inaccessible.';
    END IF;

    -- Handle OLD data
    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        UPDATE public.inventory SET quantity = quantity - OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    END IF;

    -- Handle NEW data
    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        SELECT quantity, avg_cost INTO v_qty, v_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
        IF (COALESCE(v_qty, 0) + NEW.quantity) > 0 THEN 
            v_cost := ((COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) + (NEW.quantity * NEW.rate_per_unit)) / (COALESCE(v_qty, 0) + NEW.quantity); 
        END IF;
        
        UPDATE public.inventory SET quantity = quantity + NEW.quantity, avg_cost = v_cost WHERE fuel_type_id = NEW.fuel_type_id;
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv, NULL, NEW.total_amount, 0, 'Inventory Purchase'),
               (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap, NEW.party_id, 0, NEW.total_amount, 'Accounts Payable');
        RETURN NEW;
    END IF;
    
    RETURN NULL;
END; $$;

--------------------------------------------------------------------------------
-- 2. SALE TRIGGER
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_sale_v11()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE v_inv UUID; v_cogs UUID; v_rev UUID; v_ar UUID; v_cost NUMERIC;
BEGIN
    SELECT id INTO v_inv FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs FROM accounts WHERE slug = 'cogs';
    SELECT id INTO v_rev FROM accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_ar FROM accounts WHERE slug = 'ar';

    IF v_inv IS NULL OR v_cogs IS NULL OR v_rev IS NULL OR v_ar IS NULL THEN
        RAISE EXCEPTION 'SALE TRIGGER ERROR: System accounts (inventory, cogs, sales_revenue, or ar) missing or inaccessible.';
    END IF;
    
    -- Handle OLD data
    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        UPDATE public.inventory SET quantity = quantity + OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    END IF;

    -- Handle NEW data
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
    
    RETURN NULL;
END; $$;

COMMIT;

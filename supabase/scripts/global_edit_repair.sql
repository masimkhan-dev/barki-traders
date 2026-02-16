-- =================================================================
-- GLOBAL ACCOUNTING INTEGRITY & EDIT RULE REPAIR
-- =================================================================

BEGIN;

SET search_path = public;

--------------------------------------------------------------------------------
-- 1. HARDENED SALE UPDATE TRIGGER
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_sale_v11()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_inv_id UUID; v_cogs_id UUID; v_rev_id UUID; v_ar_id UUID; v_cash_id UUID; v_cost NUMERIC; v_dr_id UUID; v_party_id UUID; v_nar TEXT;
BEGIN
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM accounts WHERE slug = 'cogs';
    SELECT id INTO v_rev_id FROM accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_cash_id FROM accounts WHERE slug = 'cash';

    -- REVERSAL LOGIC: Agar edit ho raha hai toh purana asar khatam karo
    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        UPDATE public.inventory SET quantity = quantity + OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    END IF;

    -- NEW ENTRY LOGIC: Naya data apply karo
    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        IF NEW.is_credit THEN v_dr_id := v_ar_id; v_party_id := NEW.party_id; v_nar := 'Fuel Sale (Credit)';
        ELSE v_dr_id := v_cash_id; v_party_id := NULL; v_nar := 'Fuel Sale (Cash)'; END IF;

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

--------------------------------------------------------------------------------
-- 2. HARDENED PURCHASE UPDATE TRIGGER
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_purchase_v11()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_inv_id UUID; v_ap_id UUID; v_qty NUMERIC; v_cost NUMERIC;
BEGIN
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';

    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        UPDATE public.inventory SET quantity = quantity - OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    END IF;

    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        SELECT quantity, avg_cost INTO v_qty, v_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
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
-- 3. PARTY BALANCE SYNC RULE (Ensures Running Balance is Real)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_party_balance_on_ledger_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    -- This trigger ensures that whenever a ledger entry is Updated or Deleted, 
    -- the party's current_balance column is perfectly recalculated.
    IF (OLD.party_id IS NOT NULL) THEN
        UPDATE public.parties 
        SET current_balance = (
            SELECT COALESCE(SUM(debit_amount) - SUM(credit_amount), 0)
            FROM public.ledger_entries WHERE party_id = OLD.party_id
        ) WHERE id = OLD.party_id;
    END IF;
    IF (NEW.party_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.party_id <> OLD.party_id)) THEN
        UPDATE public.parties 
        SET current_balance = (
            SELECT COALESCE(SUM(debit_amount) - SUM(credit_amount), 0)
            FROM public.ledger_entries WHERE party_id = NEW.party_id
        ) WHERE id = NEW.party_id;
    END IF;
    RETURN NULL;
END; $$;

CREATE TRIGGER trg_sync_party_balance 
AFTER INSERT OR UPDATE OR DELETE ON public.ledger_entries
FOR EACH ROW EXECUTE FUNCTION public.update_party_balance_on_ledger_change();

COMMIT;

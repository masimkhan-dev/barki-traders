-- V11 SMART TRIGGERS (HARDENED)
-- Purpose: Enable Edit for Munshi, Delete for Admin, and full auto-reconciliation.

-- 1. CLEANUP OLD IMMUTABILITY LOCKS
DROP TRIGGER IF EXISTS trigger_prevent_ledger_update ON public.ledger_entries;
DROP TRIGGER IF EXISTS trigger_prevent_ledger_delete ON public.ledger_entries;
DROP TRIGGER IF EXISTS prevent_sales_update ON public.sales;
DROP TRIGGER IF EXISTS prevent_sales_delete ON public.sales;
DROP TRIGGER IF EXISTS prevent_purchases_update ON public.purchases;
DROP TRIGGER IF EXISTS prevent_purchases_delete ON public.purchases;
DROP TRIGGER IF EXISTS prevent_payments_update ON public.payments;
DROP TRIGGER IF EXISTS prevent_payments_delete ON public.payments;

-- 2. HELPER: PERMISSION CHECK
CREATE OR REPLACE FUNCTION public.check_v11_permission(p_action TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_role TEXT;
BEGIN
    SELECT role INTO v_role FROM public.user_roles WHERE user_id = auth.uid();
    
    IF p_action = 'DELETE' AND v_role != 'admin' THEN
        RAISE EXCEPTION 'PERMISSION DENIED: Only the Super Owner (Admin) can delete records.';
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

--------------------------------------------------------------------------------
-- 3. SMART PURCHASE TRIGGER
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_purchase_v11()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_inventory_acct UUID;
    v_ap_acct UUID;
BEGIN
    PERFORM public.check_v11_permission(TG_OP);
    SELECT id INTO v_inventory_acct FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap_acct FROM public.accounts WHERE slug = 'ap';

    IF (TG_OP = 'DELETE') THEN
        UPDATE public.inventory SET quantity = quantity - OLD.quantity, last_updated = NOW() WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        INSERT INTO public.audit_logs (table_name, record_id, action, old_data, changed_by) VALUES ('purchases', OLD.id, 'DELETE', to_jsonb(OLD), auth.uid());
        RETURN OLD;
    END IF;

    IF (TG_OP = 'INSERT') THEN
        INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
        VALUES (NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit, NOW())
        ON CONFLICT (fuel_type_id) DO UPDATE
        SET quantity = inventory.quantity + NEW.quantity,
            avg_cost = ((inventory.quantity * inventory.avg_cost) + (NEW.quantity * NEW.rate_per_unit)) / NULLIF(inventory.quantity + NEW.quantity, 0),
            last_updated = NOW();

        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_acct, NULL, NEW.total_amount, 0, 'Inventory Purchase', NEW.created_by),
            (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_acct, NEW.party_id, 0, NEW.total_amount, 'Purchase from Supplier', NEW.created_by);
        RETURN NEW;
    END IF;

    IF (TG_OP = 'UPDATE') THEN
        UPDATE public.inventory 
        SET quantity = quantity - OLD.quantity + NEW.quantity,
            last_updated = NOW()
        WHERE fuel_type_id = NEW.fuel_type_id;

        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_acct, NULL, NEW.total_amount, 0, 'Inventory Purchase (REVISED)', auth.uid()),
            (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_acct, NEW.party_id, 0, NEW.total_amount, 'Purchase from Supplier (REVISED)', auth.uid());

        INSERT INTO public.audit_logs (table_name, record_id, action, old_data, new_data, changed_by) VALUES ('purchases', NEW.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW), auth.uid());
        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS on_purchase_update_inventory ON public.purchases;
DROP TRIGGER IF EXISTS sync_purchase_v11_trigger ON public.purchases;
CREATE TRIGGER sync_purchase_v11_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.purchases
    FOR EACH ROW EXECUTE FUNCTION public.sync_purchase_v11();

--------------------------------------------------------------------------------
-- 4. SMART SALE TRIGGER
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_sale_v11()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_inventory_acct UUID;
    v_cogs_acct UUID;
    v_revenue_acct UUID;
    v_ar_acct UUID;
    v_avg_cost NUMERIC;
BEGIN
    PERFORM public.check_v11_permission(TG_OP);
    SELECT id INTO v_inventory_acct FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_acct FROM public.accounts WHERE slug = 'cogs';
    SELECT id INTO v_revenue_acct FROM public.accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_ar_acct FROM public.accounts WHERE slug = 'ar';

    IF (TG_OP = 'DELETE') THEN
        UPDATE public.inventory SET quantity = quantity + OLD.quantity, last_updated = NOW() WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        INSERT INTO public.audit_logs (table_name, record_id, action, old_data, changed_by) VALUES ('sales', OLD.id, 'DELETE', to_jsonb(OLD), auth.uid());
        RETURN OLD;
    END IF;

    IF (TG_OP = 'INSERT') THEN
        SELECT COALESCE(avg_cost, 0) INTO v_avg_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
        UPDATE public.inventory SET quantity = quantity - NEW.quantity, last_updated = NOW() WHERE fuel_type_id = NEW.fuel_type_id;
        
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_acct, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale (Credit)', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_acct, NULL, 0, NEW.total_amount, 'Sales Revenue', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_acct, NULL, (NEW.quantity * v_avg_cost), 0, 'Cost of Goods Sold', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_acct, NULL, 0, (NEW.quantity * v_avg_cost), 'Inventory Reduction (COGS)', NEW.created_by);
        RETURN NEW;
    END IF;

    IF (TG_OP = 'UPDATE') THEN
        UPDATE public.inventory SET quantity = quantity + OLD.quantity - NEW.quantity, last_updated = NOW() WHERE fuel_type_id = NEW.fuel_type_id;
        SELECT COALESCE(avg_cost, 0) INTO v_avg_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
        
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_acct, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale (REVISED)', auth.uid()),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_acct, NULL, 0, NEW.total_amount, 'Sales Revenue (REVISED)', auth.uid()),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_acct, NULL, (NEW.quantity * v_avg_cost), 0, 'COGS (REVISED)', auth.uid()),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_acct, NULL, 0, (NEW.quantity * v_avg_cost), 'Stock Adj (REVISED)', auth.uid());

        INSERT INTO public.audit_logs (table_name, record_id, action, old_data, new_data, changed_by) VALUES ('sales', NEW.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW), auth.uid());
        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trigger_auto_post_sale ON public.sales;
DROP TRIGGER IF EXISTS sync_sale_v11_trigger ON public.sales;
CREATE TRIGGER sync_sale_v11_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.sales
    FOR EACH ROW EXECUTE FUNCTION public.sync_sale_v11();

--------------------------------------------------------------------------------
-- 5. SMART PAYMENT TRIGGER
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_payment_v11()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_cash_id UUID;
    v_ar_id UUID;
    v_ap_id UUID;
BEGIN
    PERFORM public.check_v11_permission(TG_OP);
    SELECT id INTO v_cash_id FROM public.accounts WHERE slug = 'cash';
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';

    IF (TG_OP = 'DELETE') THEN
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        INSERT INTO public.audit_logs (table_name, record_id, action, old_data, changed_by) VALUES ('payments', OLD.id, 'DELETE', to_jsonb(OLD), auth.uid());
        RETURN OLD;
    END IF;

    IF (TG_OP = 'INSERT') THEN
        IF NEW.payment_type = 'receipt' THEN
            INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
            VALUES (NEW.voucher_no, 'receipt', NEW.payment_date, v_cash_id, NULL, NEW.amount, 0, 'Cash Receipt', NEW.created_by),
                   (NEW.voucher_no, 'receipt', NEW.payment_date, v_ar_id, NEW.party_id, 0, NEW.amount, 'Receipt from Customer', NEW.created_by);
        ELSE
            INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
            VALUES (NEW.voucher_no, 'payment', NEW.payment_date, v_ap_id, NEW.party_id, NEW.amount, 0, 'Payment to Supplier', NEW.created_by),
                   (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, 0, NEW.amount, 'Cash Payment', NEW.created_by);
        END IF;
        RETURN NEW;
    END IF;

    IF (TG_OP = 'UPDATE') THEN
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        IF NEW.payment_type = 'receipt' THEN
            INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
            VALUES (NEW.voucher_no, 'receipt', NEW.payment_date, v_cash_id, NULL, NEW.amount, 0, 'Cash Receipt (REVISED)', auth.uid()),
                   (NEW.voucher_no, 'receipt', NEW.payment_date, v_ar_id, NEW.party_id, 0, NEW.amount, 'Receipt from Customer (REVISED)', auth.uid());
        ELSE
            INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
            VALUES (NEW.voucher_no, 'payment', NEW.payment_date, v_ap_id, NEW.party_id, NEW.amount, 0, 'Payment to Supplier (REVISED)', auth.uid()),
                   (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, 0, NEW.amount, 'Cash Payment (REVISED)', auth.uid());
        END IF;
        INSERT INTO public.audit_logs (table_name, record_id, action, old_data, new_data, changed_by) VALUES ('payments', NEW.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW), auth.uid());
        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trigger_auto_post_payment ON public.payments;
DROP TRIGGER IF EXISTS sync_payment_v11_trigger ON public.payments;
CREATE TRIGGER sync_payment_v11_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.payments
    FOR EACH ROW EXECUTE FUNCTION public.sync_payment_v11();

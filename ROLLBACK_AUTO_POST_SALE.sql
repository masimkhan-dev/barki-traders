-- =================================================================================
-- ROLLBACK SCRIPT: RESTORE ORIGINAL auto_post_sale FUNCTION
-- Purpose: Safely removes the Zero-Floor COGS logic and restores the exact
--          original production AVCO calculation logic from Jan 30, 2026.
-- =================================================================================

CREATE OR REPLACE FUNCTION public.auto_post_sale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ar_id UUID;
    v_revenue_id UUID;
    v_inventory_id UUID;
    v_cogs_id UUID;
    v_current_stock NUMERIC;
    v_avg_cost NUMERIC;
    v_cogs_amount NUMERIC;
BEGIN
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_revenue_id FROM public.accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_inventory_id FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM public.accounts WHERE slug = 'cogs';
    
    -- Stock check
    SELECT quantity, avg_cost INTO v_current_stock, v_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;
    
    IF v_current_stock < NEW.quantity THEN
        RAISE EXCEPTION 'Insufficient stock. Have: %, Need: %', v_current_stock, NEW.quantity;
    END IF;

    v_cogs_amount := NEW.quantity * v_avg_cost;

    -- 1. AR Entry (With Qty/Rate)
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale - Credit', NEW.quantity, NEW.rate_per_unit);

    -- 2. Revenue Entry
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sale Revenue');

    -- 3. COGS & Inventory Entry
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES 
        (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL, v_cogs_amount, 0, 'COGS - Sale'),
        (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_id, NULL, 0, v_cogs_amount, 'Inventory Reduction');

    -- Update inventory
    UPDATE public.inventory SET quantity = quantity - NEW.quantity WHERE fuel_type_id = NEW.fuel_type_id;
    
    RETURN NEW;
END;
$$;

RAISE NOTICE 'SUCCESS: Rolled back to original auto_post_sale logic.';

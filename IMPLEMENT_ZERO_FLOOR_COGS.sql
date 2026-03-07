-- =================================================================================
-- ZERO-FLOOR COGS IMPLEMENTATION (PERMANENT ACCOUNTING RULE)
-- Purpose: Safely limits Cost of Goods Sold (COGS) to the actual remaining
--          financial balance of the Inventory Control account, preventing
--          artificial negative ledger balances due to AVCO rate fluctuations.
-- =================================================================================

-- Drop the restrictive trigger if it exists from earlier scripts
DROP TRIGGER IF EXISTS trg_prevent_negative_inventory ON public.ledger_entries;
DROP FUNCTION IF EXISTS public.validate_inventory_balance_before_post();

-- Replace the actual sales posting function
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
    v_current_inventory_financial_balance NUMERIC;
BEGIN
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_revenue_id FROM public.accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_inventory_id FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM public.accounts WHERE slug = 'cogs';
    
    -- Stock check (Physical Quantity remains accurate)
    SELECT quantity, avg_cost INTO v_current_stock, v_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;
    
    IF v_current_stock < NEW.quantity THEN
        RAISE EXCEPTION 'Insufficient stock. Have: %, Need: %', v_current_stock, NEW.quantity;
    END IF;

    -- Calculate standard COGS using AVCO
    v_cogs_amount := NEW.quantity * v_avg_cost;

    -- =========================================================================
    -- ZERO-FLOOR COGS CAPPING LOGIC (The Permanent Accounting Rule)
    -- =========================================================================
    
    -- 1. Determine the EXACT current financial balance of the Inventory Ledger
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    INTO v_current_inventory_financial_balance
    FROM public.ledger_entries
    WHERE account_id = v_inventory_id
      AND (is_reversed IS NULL OR is_reversed = false);

    -- 2. Cap the COGS if it exceeds the remaining ledger value
    IF v_cogs_amount > v_current_inventory_financial_balance THEN
        -- If ledger has less money than the calculated COGS, only deduct what's left
        v_cogs_amount := v_current_inventory_financial_balance;
    END IF;
    
    -- Safety Fallback: Don't allow negative COGS
    IF v_cogs_amount < 0 THEN
        v_cogs_amount := 0;
    END IF;

    -- =========================================================================

    -- 1. AR Entry (With Qty/Rate)
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale - Credit', NEW.quantity, NEW.rate_per_unit);

    -- 2. Revenue Entry
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sale Revenue');

    -- 3. COGS & Inventory Entry (Using the safely capped v_cogs_amount)
    -- Only post COGS if there is actual value to deduct
    IF v_cogs_amount > 0 THEN
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL, v_cogs_amount, 0, 'COGS - Sale'),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_id, NULL, 0, v_cogs_amount, 'Inventory Reduction');
    END IF;

    -- Update inventory quantity normally
    UPDATE public.inventory SET quantity = quantity - NEW.quantity WHERE fuel_type_id = NEW.fuel_type_id;
    
    RETURN NEW;
END;
$$;

DO $$ BEGIN RAISE NOTICE 'SUCCESS: auto_post_sale updated with Zero-Floor COGS Rule.'; END $$;

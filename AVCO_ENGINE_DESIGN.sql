-- =================================================================================
-- MASTER AVCO ENGINE DESIGN (ERP-GRADE DETERMINISTIC VALUATION)
-- =================================================================================
-- This script replaces the "ledger-based" valuation with a "State-based" engine.
-- Rule: The Inventory Table is the Source of Truth. The Ledger follows.
-- =================================================================================

BEGIN;

-- ---------------------------------------------------------------------------------
-- STEP 1: Ensure Inventory Table is set up for high-precision AVCO
-- ---------------------------------------------------------------------------------
-- We use NUMERIC(20, 4) to prevent rounding drift over thousands of transactions.
ALTER TABLE public.inventory ADD COLUMN IF NOT EXISTS avg_cost NUMERIC(20, 4) DEFAULT 0;

-- ---------------------------------------------------------------------------------
-- STEP 2: The Purchase Engine (Mixing Logic)
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_post_purchase()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ap_id UUID;
    v_inventory_id UUID := '7a3a5007-4f04-442f-b3b3-4dd88876dc45';
    v_current_qty NUMERIC;
    v_current_avg_cost NUMERIC;
    v_new_total_qty NUMERIC;
    v_new_avg_cost NUMERIC;
BEGIN
    -- 1. Get current Master State (FOR UPDATE locks the row for thread safety)
    SELECT quantity, COALESCE(avg_cost, 0) 
    INTO v_current_qty, v_current_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

    -- 2. Recalculate Weighted Average Cost (Moving Average)
    v_new_total_qty := v_current_qty + NEW.quantity;
    
    IF v_new_total_qty > 0 THEN
        v_new_avg_cost := ((v_current_qty * v_current_avg_cost) + (NEW.quantity * NEW.rate_per_unit)) / v_new_total_qty;
    ELSE
        v_new_avg_cost := NEW.rate_per_unit;
    END IF;

    -- 3. Update Master State
    UPDATE public.inventory 
    SET 
        quantity = v_new_total_qty, 
        avg_cost = v_new_avg_cost,
        last_updated = now()
    WHERE fuel_type_id = NEW.fuel_type_id;

    -- 4. Post Ledger Entries (Standard Double Entry)
    -- Ledger only records what happened; it doesn't decide the math.
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
    
    -- Credit Supplier (AP)
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id, 0, NEW.total_amount, 'Fuel Purchase - Credit');

    -- Debit Inventory (Asset)
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_id, NULL, NEW.total_amount, 0, 'Inventory Addition');

    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------------
-- STEP 3: The Sale Engine (Deterministic Costing)
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_post_sale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ar_id UUID;
    v_revenue_id UUID;
    v_inventory_id UUID := '7a3a5007-4f04-442f-b3b3-4dd88876dc45';
    v_cogs_id UUID := '61866c84-ca87-4b61-ad50-32deded8339c';
    v_current_qty NUMERIC;
    v_current_avg_cost NUMERIC;
    v_cogs_to_post NUMERIC;
BEGIN
    -- 1. Get current Master State
    SELECT quantity, COALESCE(avg_cost, 0) 
    INTO v_current_qty, v_current_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

    -- 2. Stock Check
    IF v_current_qty < NEW.quantity THEN
        RAISE EXCEPTION 'Insufficient stock. Master State: %, Request: %', v_current_qty, NEW.quantity;
    END IF;

    -- 3. Calculate Deterministic COGS
    v_cogs_to_post := NEW.quantity * v_current_avg_cost;

    -- 4. Update Master State
    UPDATE public.inventory 
    SET 
        quantity = quantity - NEW.quantity,
        last_updated = now()
    WHERE fuel_type_id = NEW.fuel_type_id;

    -- 5. Post Ledger Entries
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_revenue_id FROM public.accounts WHERE slug = 'sales_revenue';

    -- Revenue & Receivable
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale - Credit', NEW.quantity, NEW.rate_per_unit);

    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sale Revenue');

    -- COGS & Inventory Reduction (Deterministic)
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES 
        (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL, v_cogs_to_post, 0, 'COGS - Deterministic'),
        (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_id, NULL, 0, v_cogs_to_post, 'Inventory Reduction (Engine)');

    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------------
-- STEP 4: One-Time Alignment (Reconciliation Bridge)
-- ---------------------------------------------------------------------------------
-- This does NOT delete anything. It simply adds a bridge entry to make the Ledger
-- match the Master Clock.
DO $$
DECLARE
    v_inv_id uuid := '7a3a5007-4f04-442f-b3b3-4dd88876dc45';
    v_cogs_id uuid := '61866c84-ca87-4b61-ad50-32deded8339c';
    v_current_ledger numeric;
    v_current_physical_value numeric;
    v_diff numeric;
    v_voucher text := 'RECON-' || TO_CHAR(NOW(), 'YYYYMMDD');
BEGIN
    -- Get current ledger balance
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0) INTO v_current_ledger
    FROM public.ledger_entries WHERE account_id = v_inv_id AND (is_reversed IS NULL OR is_reversed = false);

    -- Get target value from Master Engine (Qty * AvgCost)
    SELECT COALESCE(SUM(quantity * COALESCE(avg_cost, 0)), 0) INTO v_current_physical_value
    FROM public.inventory;

    v_diff := v_current_ledger - v_current_physical_value;

    IF ABS(v_diff) > 0.01 THEN
        INSERT INTO public.ledger_entries 
        (voucher_no, voucher_type, account_id, debit_amount, credit_amount, posting_date, narration, created_by)
        VALUES 
        (v_voucher, 'adjustment', v_cogs_id, CASE WHEN v_diff > 0 THEN v_diff ELSE 0 END, CASE WHEN v_diff < 0 THEN ABS(v_diff) ELSE 0 END, CURRENT_DATE, 'Engine Alignment: Bridging Ledger to Master State', 'SYSTEM'),
        (v_voucher, 'adjustment', v_inv_id, CASE WHEN v_diff < 0 THEN ABS(v_diff) ELSE 0 END, CASE WHEN v_diff > 0 THEN v_diff ELSE 0 END, CURRENT_DATE, 'Engine Alignment: Bridging Ledger to Master State', 'SYSTEM');
    END IF;
END $$;

COMMIT;

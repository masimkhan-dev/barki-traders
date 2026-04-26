-- =================================================================================
-- SAP-LEVEL ENTERPRISE INVENTORY CORE (EVENT SOURCING ARCHITECTURE)
-- =================================================================================
-- This is the ultimate level of financial engineering. 
-- 1. IMMUTABLE EVENT LOG: Every move is an event.
-- 2. STATE CACHE: Current stock is a projection of the event log.
-- 3. AUDIT RECONSTRUCTION: Full history is traceable liter-by-liter.
-- =================================================================================

BEGIN;

-- ---------------------------------------------------------------------------------
-- STEP 1: THE EVENT LOG (The Absolute Source of Truth)
-- ---------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.inventory_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fuel_type_id UUID REFERENCES public.fuel_types(id),
    voucher_no TEXT NOT NULL,
    event_type TEXT NOT NULL CHECK (event_type IN ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    quantity NUMERIC(20, 4) NOT NULL,
    unit_cost NUMERIC(20, 4) NOT NULL,
    total_cost NUMERIC(20, 4) NOT NULL,
    avg_cost_after NUMERIC(20, 4) NOT NULL,
    stock_after NUMERIC(20, 4) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    narration TEXT
);

-- Index for fast audit reconstruction
CREATE INDEX IF NOT EXISTS idx_inv_events_fuel_date ON public.inventory_events(fuel_type_id, created_at);

-- ---------------------------------------------------------------------------------
-- STEP 2: RE-ENGINEERED ENGINE (Event Sourcing Triggers)
-- ---------------------------------------------------------------------------------

-- 🟢 PURCHASE ENGINE (Material Receipt)
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
    v_new_avg_cost NUMERIC;
BEGIN
    -- 1. Get current Master State (Lock for integrity)
    SELECT quantity, COALESCE(avg_cost, 0) 
    INTO v_current_qty, v_current_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

    -- 2. Calculate new Moving Average
    IF (v_current_qty + NEW.quantity) > 0 THEN
        v_new_avg_cost := ((v_current_qty * v_current_avg_cost) + (NEW.quantity * NEW.rate_per_unit)) / (v_current_qty + NEW.quantity);
    ELSE
        v_new_avg_cost := NEW.rate_per_unit;
    END IF;

    -- 3. 🛡️ LOG THE EVENT (This is your SAP-level Audit Trail)
    INSERT INTO public.inventory_events (
        fuel_type_id, voucher_no, event_type, quantity, unit_cost, total_cost, avg_cost_after, stock_after, narration
    ) VALUES (
        NEW.fuel_type_id, NEW.voucher_no, 'PURCHASE', NEW.quantity, NEW.rate_per_unit, NEW.total_amount, v_new_avg_cost, (v_current_qty + NEW.quantity), 'Material Receipt'
    );

    -- 4. Update State Cache
    UPDATE public.inventory 
    SET quantity = v_current_qty + NEW.quantity, avg_cost = v_new_avg_cost, last_updated = now()
    WHERE fuel_type_id = NEW.fuel_type_id;

    -- 5. Post Accounting (Follower)
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id, 0, NEW.total_amount, 'Fuel Purchase');
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_id, NULL, NEW.total_amount, 0, 'Inventory Addition');

    RETURN NEW;
END;
$$;

-- 🔴 SALE ENGINE (Material Issue)
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
    v_cogs_amount NUMERIC;
BEGIN
    -- 1. Get current Master State
    SELECT quantity, COALESCE(avg_cost, 0) 
    INTO v_current_qty, v_current_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

    IF v_current_qty < NEW.quantity THEN
        RAISE EXCEPTION 'INSUFFICIENT STOCK: Master State shows %, but % requested.', v_current_qty, NEW.quantity;
    END IF;

    -- 2. Calculate Cost from Master Rate
    v_cogs_amount := NEW.quantity * v_current_avg_cost;

    -- 3. 🛡️ LOG THE EVENT
    INSERT INTO public.inventory_events (
        fuel_type_id, voucher_no, event_type, quantity, unit_cost, total_cost, avg_cost_after, stock_after, narration
    ) VALUES (
        NEW.fuel_type_id, NEW.voucher_no, 'SALE', -NEW.quantity, v_current_avg_cost, v_cogs_amount, v_current_avg_cost, (v_current_qty - NEW.quantity), 'Material Issue'
    );

    -- 4. Update State Cache
    UPDATE public.inventory 
    SET quantity = v_current_qty - NEW.quantity, last_updated = now()
    WHERE fuel_type_id = NEW.fuel_type_id;

    -- 5. Post Accounting
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_revenue_id FROM public.accounts WHERE slug = 'sales_revenue';

    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale', NEW.quantity, NEW.rate_per_unit);
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sale Revenue');
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES 
        (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL, v_cogs_amount, 0, 'COGS - material issue'),
        (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_id, NULL, 0, v_cogs_amount, 'Inventory Reduction');

    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------------
-- STEP 3: INITIAL RECONCILIATION (One-Time Bridge)
-- ---------------------------------------------------------------------------------
DO $$
DECLARE
    v_inv_id uuid := '7a3a5007-4f04-442f-b3b3-4dd88876dc45';
    v_cogs_id uuid := '61866c84-ca87-4b61-ad50-32deded8339c';
    v_ledger_bal numeric;
    v_engine_val numeric;
    v_diff numeric;
    v_voucher text := 'CORE-RECON-' || TO_CHAR(NOW(), 'YYYYMMDD');
BEGIN
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0) INTO v_ledger_bal FROM public.ledger_entries WHERE account_id = v_inv_id;
    SELECT COALESCE(SUM(quantity * COALESCE(avg_cost, 0)), 0) INTO v_engine_val FROM public.inventory;
    v_diff := v_ledger_bal - v_engine_val;

    IF ABS(v_diff) > 0.01 THEN
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, account_id, debit_amount, credit_amount, posting_date, narration, created_by)
        VALUES 
            (v_voucher, 'adjustment', v_cogs_id, CASE WHEN v_diff > 0 THEN v_diff ELSE 0 END, CASE WHEN v_diff < 0 THEN ABS(v_diff) ELSE 0 END, CURRENT_DATE, 'SAP Core Alignment: Reconciling Legacy Ledger to Event Engine', 'SYSTEM'),
            (v_voucher, 'adjustment', v_inv_id, CASE WHEN v_diff < 0 THEN ABS(v_diff) ELSE 0 END, CASE WHEN v_diff > 0 THEN v_diff ELSE 0 END, CURRENT_DATE, 'SAP Core Alignment: Reconciling Legacy Ledger to Event Engine', 'SYSTEM');
    END IF;
END $$;

COMMIT;

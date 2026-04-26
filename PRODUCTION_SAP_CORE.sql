-- =================================================================================
-- PRODUCTION SAP-LEVEL CORE (EVENT-SOURCED SELF-HEALING ARCHITECTURE)
-- =================================================================================
-- 1. IMMUTABLE LOG: inventory_events (The only source of truth)
-- 2. DISPOSABLE CACHE: inventory (Speed layer, can be rebuilt anytime)
-- 3. REPLAY ENGINE: reconstruct_inventory_state() (Self-healing logic)
-- =================================================================================

BEGIN;

-- ---------------------------------------------------------------------------------
-- STEP 1: THE EVENT LOG (Audit-Safe Material Movement)
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

-- Index for sequential replay
CREATE INDEX IF NOT EXISTS idx_inv_events_replay ON public.inventory_events(fuel_type_id, created_at ASC);

-- ---------------------------------------------------------------------------------
-- STEP 2: THE REPLAY ENGINE (The "Self-Healing" Brain)
-- ---------------------------------------------------------------------------------
-- This function can rebuild your entire stock state from the event history.
-- If the inventory table ever drifts, run this to fix it instantly.
CREATE OR REPLACE FUNCTION public.reconstruct_inventory_state(p_fuel_type_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_qty NUMERIC := 0;
    v_val NUMERIC := 0;
    v_avg_cost NUMERIC := 0;
    r RECORD;
BEGIN
    -- 1. Replay every event in chronological order
    FOR r IN (
        SELECT event_type, quantity, unit_cost, total_cost 
        FROM public.inventory_events 
        WHERE fuel_type_id = p_fuel_type_id 
        ORDER BY created_at ASC
    ) LOOP
        IF r.event_type = 'PURCHASE' THEN
            v_qty := v_qty + r.quantity;
            v_val := v_val + r.total_cost;
            IF v_qty > 0 THEN
                v_avg_cost := v_val / v_qty;
            END IF;
        ELSIF r.event_type = 'SALE' THEN
            -- In a true replay, we use the average cost at the time of sale
            v_qty := v_qty - r.quantity;
            v_val := v_val - (r.quantity * v_avg_cost);
        ELSIF r.event_type = 'ADJUSTMENT' THEN
            v_qty := v_qty + r.quantity;
            v_val := v_val + r.total_cost;
            IF v_qty > 0 THEN
                v_avg_cost := v_val / v_qty;
            ELSE
                v_avg_cost := 0;
            END IF;
        END IF;
    END LOOP;

    -- 2. Update the Disposable Cache
    UPDATE public.inventory 
    SET 
        quantity = COALESCE(v_qty, 0), 
        avg_cost = COALESCE(v_avg_cost, 0),
        last_updated = now()
    WHERE fuel_type_id = p_fuel_type_id;

    RAISE NOTICE 'SUCCESS: Rebuilt state for %. Qty: %, AvgCost: %', p_fuel_type_id, v_qty, v_avg_cost;
END;
$$;

-- ---------------------------------------------------------------------------------
-- STEP 3: RE-ENGINEERED TRIGGERS (Strict Governance)
-- ---------------------------------------------------------------------------------

-- 🟢 PURCHASE ENGINE
CREATE OR REPLACE FUNCTION public.auto_post_purchase()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_inventory_id UUID := '7a3a5007-4f04-442f-b3b3-4dd88876dc45';
    v_ap_id UUID;
    v_current_qty NUMERIC;
    v_current_avg_cost NUMERIC;
    v_new_avg_cost NUMERIC;
BEGIN
    -- 1. Read Current Cache (FOR UPDATE)
    SELECT quantity, COALESCE(avg_cost, 0) INTO v_current_qty, v_current_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

    -- 2. Compute New State
    IF (v_current_qty + NEW.quantity) > 0 THEN
        v_new_avg_cost := ((v_current_qty * v_current_avg_cost) + (NEW.quantity * NEW.rate_per_unit)) / (v_current_qty + NEW.quantity);
    ELSE
        v_new_avg_cost := NEW.rate_per_unit;
    END IF;

    -- 3. LOG TO IMMUTABLE TRUTH (FIRST)
    INSERT INTO public.inventory_events (
        fuel_type_id, voucher_no, event_type, quantity, unit_cost, total_cost, avg_cost_after, stock_after, narration
    ) VALUES (
        NEW.fuel_type_id, NEW.voucher_no, 'PURCHASE', NEW.quantity, NEW.rate_per_unit, NEW.total_amount, v_new_avg_cost, (v_current_qty + NEW.quantity), 'Material Receipt'
    );

    -- 4. UPDATE DISPOSABLE CACHE
    UPDATE public.inventory 
    SET quantity = v_current_qty + NEW.quantity, avg_cost = v_new_avg_cost, last_updated = now()
    WHERE fuel_type_id = NEW.fuel_type_id;

    -- 5. POST ACCOUNTING
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id, 0, NEW.total_amount, 'Fuel Purchase');
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_id, NULL, NEW.total_amount, 0, 'Inventory Addition');

    RETURN NEW;
END;
$$;

-- 🔴 SALE ENGINE
CREATE OR REPLACE FUNCTION public.auto_post_sale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_inventory_id UUID := '7a3a5007-4f04-442f-b3b3-4dd88876dc45';
    v_cogs_id UUID := '61866c84-ca87-4b61-ad50-32deded8339c';
    v_ar_id UUID;
    v_revenue_id UUID;
    v_current_qty NUMERIC;
    v_current_avg_cost NUMERIC;
    v_cogs_amount NUMERIC;
BEGIN
    -- 1. Read Current Cache
    SELECT quantity, COALESCE(avg_cost, 0) INTO v_current_qty, v_current_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

    IF v_current_qty < NEW.quantity THEN
        RAISE EXCEPTION 'STOCK OUT: Master State: %, Requested: %', v_current_qty, NEW.quantity;
    END IF;

    v_cogs_amount := NEW.quantity * v_current_avg_cost;

    -- 2. LOG TO IMMUTABLE TRUTH
    INSERT INTO public.inventory_events (
        fuel_type_id, voucher_no, event_type, quantity, unit_cost, total_cost, avg_cost_after, stock_after, narration
    ) VALUES (
        NEW.fuel_type_id, NEW.voucher_no, 'SALE', NEW.quantity, v_current_avg_cost, v_cogs_amount, v_current_avg_cost, (v_current_qty - NEW.quantity), 'Material Issue'
    );

    -- 3. UPDATE DISPOSABLE CACHE
    UPDATE public.inventory 
    SET quantity = v_current_qty - NEW.quantity, last_updated = now()
    WHERE fuel_type_id = NEW.fuel_type_id;

    -- 4. POST ACCOUNTING
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

COMMIT;

DO $$ BEGIN RAISE NOTICE 'SUCCESS: Production SAP Core Implemented.'; END $$;

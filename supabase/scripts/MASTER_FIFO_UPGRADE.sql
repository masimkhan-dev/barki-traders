-- ============================================================
-- 🚀 SAP-GRADE FIFO INVENTORY ENGINE (V1.0)
-- ============================================================
-- Purpose: Transition from Moving Average (AVCO) to FIFO.
-- Fixes: Eliminates residual inventory drift (Rs 265,086).
-- ============================================================

BEGIN;

-- 1. SCHEMA ENHANCEMENT
-- Add remaining_qty to track available stock in each purchase lot
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'purchases' AND column_name = 'remaining_qty') THEN
        ALTER TABLE public.purchases ADD COLUMN remaining_qty NUMERIC(15,3) DEFAULT 0;
    END IF;
END $$;

-- 2. FIFO CONSUMPTION LOGIC
-- This function finds the oldest available lots and consumes them.
CREATE OR REPLACE FUNCTION public.proc_fifo_consumption(
    p_fuel_type_id UUID,
    p_qty_to_consume NUMERIC
)
RETURNS NUMERIC -- Returns the total COGS (Cost of Goods Sold) for this quantity
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_total_cogs NUMERIC := 0;
    v_remaining_needed NUMERIC := p_qty_to_consume;
    v_lot RECORD;
    v_consumed_from_lot NUMERIC;
BEGIN
    -- Loop through available purchase lots (Oldest First = FIFO)
    FOR v_lot IN (
        SELECT id, remaining_qty, rate_per_unit
        FROM public.purchases
        WHERE fuel_type_id = p_fuel_type_id AND remaining_qty > 0
        ORDER BY purchase_date ASC, created_at ASC
    )
    LOOP
        EXIT WHEN v_remaining_needed <= 0;

        -- Calculate how much to take from this lot
        v_consumed_from_lot := LEAST(v_lot.remaining_qty, v_remaining_needed);
        
        -- Update the lot's remaining quantity
        UPDATE public.purchases 
        SET remaining_qty = remaining_qty - v_consumed_from_lot
        WHERE id = v_lot.id;

        -- Add to total COGS
        v_total_cogs := v_total_cogs + (v_consumed_from_lot * v_lot.rate_per_unit);
        
        -- Deduct from what we still need to consume
        v_remaining_needed := v_remaining_needed - v_consumed_from_lot;
    END LOOP;

    -- If we still need more but lots are empty (Stockout scenario)
    -- We use the last known rate to prevent zero-cost errors
    IF v_remaining_needed > 0 THEN
        DECLARE v_last_rate NUMERIC;
        BEGIN
            SELECT rate_per_unit INTO v_last_rate FROM public.purchases WHERE fuel_type_id = p_fuel_type_id ORDER BY purchase_date DESC LIMIT 1;
            v_total_cogs := v_total_cogs + (v_remaining_needed * COALESCE(v_last_rate, 0));
        END;
    END IF;

    RETURN v_total_cogs;
END;
$$;

-- 3. HISTORICAL DATA REPAIR (The "Big Sync")
-- We will reset all remaining_qty and re-process all sales to build a clean FIFO history.

-- A. Reset all remaining_qty to initial purchase quantity
UPDATE public.purchases SET remaining_qty = quantity;

-- B. Create a temporary table to store FIFO costs for re-sync
CREATE TEMP TABLE temp_fifo_sync (
    voucher_no TEXT,
    fifo_cogs NUMERIC
);

-- C. Process all sales in chronological order to populate remaining_qty
DO $$
DECLARE
    v_sale RECORD;
    v_cogs NUMERIC;
BEGIN
    FOR v_sale IN (SELECT voucher_no, fuel_type_id, quantity FROM public.sales ORDER BY sale_date ASC, created_at ASC)
    LOOP
        v_cogs := public.proc_fifo_consumption(v_sale.fuel_type_id, v_sale.quantity);
        INSERT INTO temp_fifo_sync VALUES (v_sale.voucher_no, v_cogs);
    END LOOP;
END $$;

-- D. Update Ledger Entries with EXACT FIFO Costs
-- This replaces the old "Average" costs with "FIFO" costs.
UPDATE public.ledger_entries le
SET debit_amount = t.fifo_cogs
FROM temp_fifo_sync t
JOIN public.accounts a ON a.slug = 'cogs'
WHERE le.voucher_no = t.voucher_no 
  AND le.account_id = a.id;

UPDATE public.ledger_entries le
SET credit_amount = t.fifo_cogs
FROM temp_fifo_sync t
JOIN public.accounts a ON a.slug = 'inventory'
WHERE le.voucher_no = t.voucher_no 
  AND le.account_id = a.id;

-- 4. UPDATE INVENTORY CACHE
-- The inventory table should now match the sum of remaining_qty in purchases.
DELETE FROM public.inventory;
INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost)
SELECT 
    fuel_type_id, 
    SUM(remaining_qty), 
    CASE WHEN SUM(remaining_qty) > 0 THEN SUM(remaining_qty * rate_per_unit) / SUM(remaining_qty) ELSE 0 END
FROM public.purchases
GROUP BY fuel_type_id;

-- 5. FINAL TRIGGER UPGRADE
-- From now on, every new sale will use FIFO automatically.
CREATE OR REPLACE FUNCTION public.sync_sale_v14()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE 
    v_inv UUID; v_cogs UUID; v_rev UUID; v_ar UUID; v_fifo_cost NUMERIC;
BEGIN
    SELECT id INTO v_inv FROM public.accounts WHERE slug = 'inventory' LIMIT 1;
    SELECT id INTO v_cogs FROM public.accounts WHERE slug = 'cogs' LIMIT 1;
    SELECT id INTO v_rev FROM public.accounts WHERE slug = 'sales_revenue' LIMIT 1;
    SELECT id INTO v_ar FROM public.accounts WHERE slug = 'ar' LIMIT 1;

    IF (TG_OP = 'INSERT') THEN
        -- Execute FIFO Consumption
        v_fifo_cost := public.proc_fifo_consumption(NEW.fuel_type_id, NEW.quantity);

        -- Post Ledger
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_ar, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale (FIFO)'),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_rev, NULL, 0, NEW.total_amount, 'Sales Revenue'),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs, NULL, v_fifo_cost, 0, 'FIFO Cost of Goods Sold'),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_inv, NULL, 0, v_fifo_cost, 'Inventory Reduction (FIFO)');
        
        -- Update Cache
        UPDATE public.inventory SET quantity = quantity - NEW.quantity WHERE fuel_type_id = NEW.fuel_type_id;
        
        RETURN NEW;
    END IF;
    -- Note: Updates/Deletes in FIFO require a full re-sync. For now, we focus on safe Inserts.
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS sync_sale_v11_trigger ON public.sales;
DROP TRIGGER IF EXISTS sync_sale_v13_trigger ON public.sales;
CREATE TRIGGER sync_sale_v14_trigger AFTER INSERT ON public.sales FOR EACH ROW EXECUTE FUNCTION public.sync_sale_v14();

COMMIT;

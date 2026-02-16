-- =================================================================
-- RESTORATION MIGRATION: Inventory Business Logic
-- Purpose: Restore pre-migration working state with ledger enforcement
-- =================================================================

BEGIN;

-- =================================================================
-- SECTION 1: RESTORE INVENTORY TABLE
-- =================================================================

CREATE TABLE IF NOT EXISTS public.inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fuel_type_id UUID NOT NULL REFERENCES public.fuel_types(id) ON DELETE RESTRICT,
    quantity NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    avg_cost NUMERIC(15, 2) NOT NULL DEFAULT 0,
    last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(fuel_type_id)
);

ALTER TABLE public.inventory ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable read for authenticated users" ON public.inventory 
    FOR SELECT TO authenticated USING (true);

CREATE INDEX IF NOT EXISTS idx_inventory_fuel_type ON public.inventory(fuel_type_id);

-- Initialize inventory for existing fuel types
INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost)
SELECT id, 0, 0 FROM public.fuel_types
ON CONFLICT (fuel_type_id) DO NOTHING;

-- =================================================================
-- SECTION 2: RESTORE PURCHASE TRIGGER (Stock Increase + Ledger)
-- =================================================================

-- Drop existing trigger if present
DROP TRIGGER IF EXISTS on_purchase_update_inventory ON public.purchases;
DROP TRIGGER IF EXISTS trigger_auto_post_purchase ON public.purchases;

-- Restore inventory update function
CREATE OR REPLACE FUNCTION public.update_inventory_on_purchase()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    current_qty NUMERIC;
    current_avg_cost NUMERIC;
    new_avg_cost NUMERIC;
    v_inventory_acct UUID;
    v_ap_acct UUID;
BEGIN
    -- Get current inventory state
    SELECT quantity, avg_cost INTO current_qty, current_avg_cost 
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
    
    IF NOT FOUND THEN
        current_qty := 0;
        current_avg_cost := 0;
    END IF;

    -- Calculate new weighted average cost
    IF (current_qty + NEW.quantity) > 0 THEN
        new_avg_cost := ((current_qty * current_avg_cost) + (NEW.quantity * NEW.rate_per_unit)) / (current_qty + NEW.quantity);
    ELSE
        new_avg_cost := NEW.rate_per_unit;
    END IF;

    -- Update inventory
    INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
    VALUES (NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit, NOW())
    ON CONFLICT (fuel_type_id) DO UPDATE
    SET quantity = inventory.quantity + NEW.quantity,
        avg_cost = new_avg_cost,
        last_updated = NOW();

    -- Post to ledger: Dr Inventory, Cr AP
    SELECT id INTO v_inventory_acct FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap_acct FROM public.accounts WHERE slug = 'ap';
    
    IF v_inventory_acct IS NULL OR v_ap_acct IS NULL THEN
        RAISE EXCEPTION 'CRITICAL: Inventory or AP account missing';
    END IF;

    INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, party_id, 
        debit_amount, credit_amount, narration, created_by
    )
    VALUES 
        (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_acct, NULL, 
         NEW.total_amount, 0, 'Inventory Purchase', NEW.created_by),
        (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_acct, NEW.party_id, 
         0, NEW.total_amount, 'Purchase from Supplier', NEW.created_by);

    RETURN NEW;
END;
$$;

CREATE TRIGGER on_purchase_update_inventory
    AFTER INSERT ON public.purchases
    FOR EACH ROW
    EXECUTE FUNCTION public.update_inventory_on_purchase();

-- =================================================================
-- SECTION 3: RESTORE SALE TRIGGER (Stock Decrease + COGS + Ledger)
-- =================================================================

-- Drop and recreate sale trigger
DROP TRIGGER IF EXISTS trigger_auto_post_sale ON public.sales;
DROP TRIGGER IF EXISTS on_sale_update_inventory ON public.sales;

CREATE OR REPLACE FUNCTION public.auto_post_sale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ar_id UUID;
    v_revenue_id UUID;
    v_cash_id UUID;
    v_inventory_id UUID;
    v_cogs_id UUID;
    v_current_stock NUMERIC;
    v_avg_cost NUMERIC;
    v_cogs_amount NUMERIC;
BEGIN
    -- CRITICAL: Lock party row to prevent race conditions
    IF NEW.party_id IS NOT NULL THEN
        PERFORM 1 FROM public.parties WHERE id = NEW.party_id FOR UPDATE;
    END IF;
    
    -- Get account IDs
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_revenue_id FROM public.accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_cash_id FROM public.accounts WHERE slug = 'cash';
    SELECT id INTO v_inventory_id FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM public.accounts WHERE slug = 'cogs';
    
    IF v_ar_id IS NULL OR v_revenue_id IS NULL OR v_cash_id IS NULL OR v_inventory_id IS NULL OR v_cogs_id IS NULL THEN
        RAISE EXCEPTION 'CRITICAL: Control accounts missing for sale posting';
    END IF;

    -- STOCK VALIDATION (Database-level enforcement)
    SELECT quantity, avg_cost INTO v_current_stock, v_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
    
    IF v_current_stock IS NULL THEN
        RAISE EXCEPTION 'STOCK ERROR: Fuel type not found in inventory';
    END IF;
    
    IF v_current_stock < NEW.quantity THEN
        RAISE EXCEPTION 'STOCK ERROR: Insufficient stock. Available: %, Requested: %', v_current_stock, NEW.quantity;
    END IF;

    -- Calculate COGS
    v_cogs_amount := NEW.quantity * v_avg_cost;

    -- Update inventory (decrease stock)
    UPDATE public.inventory
    SET quantity = quantity - NEW.quantity,
        last_updated = NOW()
    WHERE fuel_type_id = NEW.fuel_type_id;
    
    -- Post to ledger based on credit/cash sale
    IF NEW.is_credit THEN
        -- Credit Sale: Dr AR, Cr Revenue
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id, NEW.total_amount, 0, 'Credit Sale - AR', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Credit Sale - Revenue', NEW.created_by);
    ELSE
        -- Cash Sale: Dr Cash, Cr Revenue
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_cash_id, NULL, NEW.total_amount, 0, 'Cash Sale', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Cash Sale - Revenue', NEW.created_by);
    END IF;

    -- COGS Entry: Dr COGS, Cr Inventory
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES 
        (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL, v_cogs_amount, 0, 'Cost of Goods Sold', NEW.created_by),
        (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_id, NULL, 0, v_cogs_amount, 'Inventory Reduction', NEW.created_by);
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_auto_post_sale
    AFTER INSERT ON public.sales
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_post_sale();

-- =================================================================
-- SECTION 4: UPDATE SOURCE VALIDATION (Allow purchase voucher type)
-- =================================================================

CREATE OR REPLACE FUNCTION public.ensure_source_document_exists()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- WHITELIST: Only allow explicitly defined voucher types
    IF NEW.voucher_type NOT IN (
        'sale',
        'purchase',
        'receipt',
        'payment',
        'opening_balance'
    ) THEN
        RAISE EXCEPTION 
            'INVALID VOUCHER TYPE: "%" is not permitted. Only sale, purchase, receipt, payment, opening_balance are allowed.',
            NEW.voucher_type
            USING HINT = 'Contact system administrator to add new voucher types';
    END IF;

    -- For sales vouchers, verify the sale exists
    IF NEW.voucher_type = 'sale' THEN
        IF NOT EXISTS (SELECT 1 FROM public.sales WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 
                'LEDGER INTEGRITY VIOLATION: Sale source document missing for voucher %. Cannot post to ledger.',
                NEW.voucher_no
                USING HINT = 'Create the sale record first, then the trigger will post to ledger automatically';
        END IF;
    END IF;

    -- For receipt/payment vouchers, verify the payment exists
    IF NEW.voucher_type IN ('receipt', 'payment') THEN
        IF NOT EXISTS (SELECT 1 FROM public.payments WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 
                'LEDGER INTEGRITY VIOLATION: Payment source document missing for voucher %. Cannot post to ledger.',
                NEW.voucher_no
                USING HINT = 'Create the payment record first, then the trigger will post to ledger automatically';
        END IF;
    END IF;

    -- For purchase vouchers, verify the purchase exists
    IF NEW.voucher_type = 'purchase' THEN
        IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 
                'LEDGER INTEGRITY VIOLATION: Purchase source document missing for voucher %. Cannot post to ledger.',
                NEW.voucher_no
                USING HINT = 'Create the purchase record first, then the trigger will post to ledger automatically';
        END IF;
    END IF;

    -- opening_balance is allowed without source (used during migration/setup)
    
    RETURN NEW;
END;
$$;

-- =================================================================
-- VALIDATION
-- =================================================================

DO $$
BEGIN
    -- Verify inventory table exists
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'inventory') THEN
        RAISE EXCEPTION 'VALIDATION FAILED: Inventory table not created';
    END IF;
    
    -- Verify triggers exist
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger 
        WHERE tgname = 'on_purchase_update_inventory'
    ) THEN
        RAISE EXCEPTION 'VALIDATION FAILED: Purchase inventory trigger missing';
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger 
        WHERE tgname = 'trigger_auto_post_sale'
    ) THEN
        RAISE EXCEPTION 'VALIDATION FAILED: Sale posting trigger missing';
    END IF;
    
    RAISE NOTICE '✅ Inventory business logic restored successfully';
END $$;

COMMIT;

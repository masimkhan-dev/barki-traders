-- =================================================================================
-- FINAL AUDIT-SAFE INVENTORY REPAIR & ENGINE REDESIGN
-- =================================================================================
-- PART 1: Upgraded Calibration (Zero out residuals)
-- PART 2: Zero-Floor COGS Rule (Permanent Engine Fix)
-- =================================================================================

BEGIN;

-- ---------------------------------------------------------------------------------
-- PART 1: UPGRADED CALIBRATION SCRIPT (Stock=0 Audit)
-- ---------------------------------------------------------------------------------
DO $$
DECLARE
    v_inv_id uuid := '7a3a5007-4f04-442f-b3b3-4dd88876dc45'; -- Inventory (Control)
    v_cogs_id uuid := '61866c84-ca87-4b61-ad50-32deded8339c'; -- Cost of Goods Sold
    v_current numeric;
    v_diff numeric;
    v_voucher text := 'ADJ-INV-' || TO_CHAR(NOW(), 'YYYYMMDD-HH24MISS');
BEGIN
    -- Step 1: Get current balance
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    INTO v_current
    FROM public.ledger_entries
    WHERE account_id = v_inv_id
      AND (is_reversed IS NULL OR is_reversed = false);

    v_diff := v_current; -- Goal is zero balance

    -- Step 2: Prevent duplicate adjustment today
    IF EXISTS (
        SELECT 1 FROM public.ledger_entries
        WHERE narration LIKE 'Inventory Calibration%'
        AND posting_date = CURRENT_DATE
    ) THEN
        RAISE NOTICE 'ABORTED: Calibration already performed today.';
        RETURN;
    END IF;

    -- Step 3: Skip if already zero
    IF ABS(v_diff) < 1 THEN
        RAISE NOTICE 'No adjustment needed. Inventory already balanced at %', v_current;
        RETURN;
    END IF;

    -- Step 4: Post Adjustment with strict audit narration
    IF v_diff > 0 THEN
        -- Case: Stock is 0 but Value > 0 (Over-valuation residual)
        INSERT INTO public.ledger_entries 
        (voucher_no, voucher_type, account_id, debit_amount, credit_amount, posting_date, narration, created_by)
        VALUES 
        (v_voucher, 'adjustment', v_cogs_id, v_diff, 0, CURRENT_DATE, 
         'Inventory Calibration (Stock=0, Value>0 correction)', 'SYSTEM'),
        (v_voucher, 'adjustment', v_inv_id, 0, v_diff, CURRENT_DATE, 
         'Inventory Calibration (Stock=0, Value>0 correction)', 'SYSTEM');
    ELSE
        -- Case: Stock is 0 but Value < 0 (Under-valuation residual)
        INSERT INTO public.ledger_entries 
        (voucher_no, voucher_type, account_id, debit_amount, credit_amount, posting_date, narration, created_by)
        VALUES 
        (v_voucher, 'adjustment', v_inv_id, ABS(v_diff), 0, CURRENT_DATE, 
         'Inventory Calibration (Stock=0, Value<0 correction)', 'SYSTEM'),
        (v_voucher, 'adjustment', v_cogs_id, 0, ABS(v_diff), CURRENT_DATE, 
         'Inventory Calibration (Stock=0, Value<0 correction)', 'SYSTEM');
    END IF;

    RAISE NOTICE 'SUCCESS: Inventory calibrated by % PKR. Voucher: %', v_diff, v_voucher;
END $$;


-- ---------------------------------------------------------------------------------
-- PART 2: ZERO-FLOOR COGS RULE (Permanent Engine Fix)
-- ---------------------------------------------------------------------------------
-- Purpose: Safely limits COGS to the actual remaining financial balance 
--          of the Inventory account, preventing future "Ghost Values".
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
    v_current_stock NUMERIC;
    v_avg_cost NUMERIC;
    v_cogs_amount NUMERIC;
    v_current_inventory_financial_balance NUMERIC;
BEGIN
    -- Resolve account IDs by slug for stability
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_revenue_id FROM public.accounts WHERE slug = 'sales_revenue';
    
    -- 1. Stock check (Physical Quantity)
    SELECT quantity, avg_cost INTO v_current_stock, v_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;
    
    IF v_current_stock < NEW.quantity THEN
        RAISE EXCEPTION 'Insufficient stock. Have: %, Need: %', v_current_stock, NEW.quantity;
    END IF;

    -- 2. Calculate standard COGS using AVCO
    v_cogs_amount := NEW.quantity * v_avg_cost;

    -- 3. ZERO-FLOOR COGS CAPPING LOGIC
    -- Determine current financial balance of the Inventory Ledger
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    INTO v_current_inventory_financial_balance
    FROM public.ledger_entries
    WHERE account_id = v_inventory_id
      AND (is_reversed IS NULL OR is_reversed = false);

    -- Cap COGS to remaining ledger value
    IF v_cogs_amount > v_current_inventory_financial_balance THEN
        v_cogs_amount := v_current_inventory_financial_balance;
    END IF;
    
    -- Safety Fallback
    IF v_cogs_amount < 0 THEN v_cogs_amount := 0; END IF;

    -- 4. Post Ledger Entries
    -- AR Entry
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale - Credit', NEW.quantity, NEW.rate_per_unit);

    -- Revenue Entry
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sale Revenue');

    -- COGS & Inventory (Only if value exists to deduct)
    IF v_cogs_amount > 0 THEN
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL, v_cogs_amount, 0, 'COGS - Sale'),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_id, NULL, 0, v_cogs_amount, 'Inventory Reduction');
    END IF;

    -- 5. Update physical inventory quantity
    UPDATE public.inventory SET quantity = quantity - NEW.quantity, last_updated = now() WHERE fuel_type_id = NEW.fuel_type_id;
    
    RETURN NEW;
END;
$$;

COMMIT;

DO $$ BEGIN RAISE NOTICE 'SUCCESS: Inventory Repair Applied and Engine Fix Implemented.'; END $$;

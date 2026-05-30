BEGIN;

-- ============================================================================
-- 1. DROP RESTRICTIVE LEDGER TRIGGERS
-- ============================================================================
-- Drop any old immutable triggers that block deleting/updating ledger entries.
-- Since the application manages all updates/deletes through secure database RPCs
-- (like edit_purchase_transaction, delete_transaction_safely) and triggers,
-- these constraints are redundant and prevent proper editing of transactions.
DROP TRIGGER IF EXISTS trg_prevent_ledger_modification_update ON public.ledger_entries;
DROP TRIGGER IF EXISTS trg_prevent_ledger_modification_delete ON public.ledger_entries;
DROP TRIGGER IF EXISTS trigger_prevent_ledger_update ON public.ledger_entries;
DROP TRIGGER IF EXISTS trigger_prevent_ledger_delete ON public.ledger_entries;
DROP TRIGGER IF EXISTS trg_prevent_ledger_modification_access ON public.ledger_entries;
DROP TRIGGER IF EXISTS trigger_sync_deletion ON public.ledger_entries;
DROP TRIGGER IF EXISTS sync_party_balance_trigger ON public.ledger_entries;
DROP FUNCTION IF EXISTS public.sync_voucher_deletion() CASCADE;

-- ============================================================================
-- 2. RE-ALIGN PURCHASES LEDGER SYNC TRIGGER
-- ============================================================================
-- Re-write proc_purchase_ledger_strict to use proper control accounts:
-- Debit: Inventory (Slug: 'inventory' / Code: '1200')
-- Credit: Accounts Payable (Slug: 'ap' / Code: '2100')
-- Also handles full ledger rebuilding correctly when fuel_type_id or other fields are edited.

CREATE OR REPLACE FUNCTION public.proc_purchase_ledger_strict()
RETURNS TRIGGER AS $$
DECLARE
    v_party_account_id UUID;
    v_purchase_account_id UUID;
    v_party_name TEXT;
    v_delta NUMERIC;
BEGIN
    -- 1. Resolve Accounts Payable (Supplier Liability)
    SELECT id INTO v_party_account_id FROM accounts WHERE slug = 'ap';
    IF v_party_account_id IS NULL THEN
        SELECT id INTO v_party_account_id FROM accounts WHERE code = '2000';
    END IF;
    
    -- 2. Resolve Inventory Account (Asset Debit)
    SELECT id INTO v_purchase_account_id FROM accounts WHERE slug = 'inventory';
    IF v_purchase_account_id IS NULL THEN
        SELECT id INTO v_purchase_account_id FROM accounts WHERE code = '1200';
    END IF;

    -- 3. Safety Check
    IF v_party_account_id IS NULL OR v_purchase_account_id IS NULL THEN
        RAISE EXCEPTION 'COMPLIANCE ERROR: Required control accounts (Accounts Payable or Inventory) are missing.';
    END IF;
    
    -- INSERT FLOW
    IF TG_OP = 'INSERT' THEN
        SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
        VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_purchase_account_id, NULL, NEW.total_amount, 0, 'Purchase from ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
        VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_party_account_id, NEW.party_id, 0, NEW.total_amount, 'Credit Purchase - ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

        PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'IN');

        RETURN NEW;
    END IF;

    -- DELETE FLOW
    IF TG_OP = 'DELETE' THEN
        PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'OUT');
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        RETURN OLD;
    END IF;

    -- UPDATE FLOW
    IF TG_OP = 'UPDATE' THEN
        -- Smart Edit bypass for stock
        IF NEW.fuel_type_id IS DISTINCT FROM OLD.fuel_type_id THEN
            -- Deduct old, add new
            PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'OUT');
            PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'IN');
        ELSIF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
            v_delta := NEW.quantity - OLD.quantity;
            IF v_delta > 0 THEN
                -- Bought more, add to stock
                PERFORM public.update_stock_quantity(NEW.fuel_type_id, v_delta, 'IN');
            ELSIF v_delta < 0 THEN
                -- Bought less, remove from stock (throws if insufficient)
                PERFORM public.update_stock_quantity(NEW.fuel_type_id, abs(v_delta), 'OUT');
            END IF;
        END IF;

        -- Handle Ledger Rebuild (on any significant changes including fuel type)
        IF NEW.total_amount IS DISTINCT FROM OLD.total_amount 
           OR NEW.rate_per_unit IS DISTINCT FROM OLD.rate_per_unit
           OR NEW.quantity IS DISTINCT FROM OLD.quantity
           OR NEW.purchase_date IS DISTINCT FROM OLD.purchase_date
           OR NEW.party_id IS DISTINCT FROM OLD.party_id
           OR NEW.fuel_type_id IS DISTINCT FROM OLD.fuel_type_id THEN
            
            SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;
            
            DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
            VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_purchase_account_id, NULL, NEW.total_amount, 0, 'Purchase from ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
            VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_party_account_id, NEW.party_id, 0, NEW.total_amount, 'Credit Purchase - ' || v_party_name, NEW.quantity, NEW.rate_per_unit);
        ELSE
            -- Narration only update
            UPDATE public.ledger_entries 
            SET narration = COALESCE(NEW.notes, 'Purchase from ' || (SELECT name FROM parties WHERE id = NEW.party_id))
            WHERE voucher_no = NEW.voucher_no AND account_id = v_purchase_account_id;
        END IF;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 3. RE-ALIGN SALES LEDGER SYNC TRIGGER
-- ============================================================================
-- Re-write proc_sale_ledger_strict to use proper control accounts:
-- Debit: Accounts Receivable (Slug: 'ar' / Code: '1100')
-- Credit: Sales Revenue (Slug: 'sales_revenue' / Code: '3100')
-- Also handles full ledger rebuilding correctly when fuel_type_id or other fields are edited.

CREATE OR REPLACE FUNCTION public.proc_sale_ledger_strict()
RETURNS TRIGGER AS $$
DECLARE
    v_party_account_id UUID;
    v_revenue_id UUID;
    v_party_name TEXT;
    v_delta NUMERIC;
BEGIN
    -- 1. Resolve Accounts Receivable (Customer Asset)
    SELECT id INTO v_party_account_id FROM accounts WHERE slug = 'ar';
    IF v_party_account_id IS NULL THEN
        SELECT id INTO v_party_account_id FROM accounts WHERE code = '1100';
    END IF;

    -- 2. Resolve Sales Revenue (Income Credit)
    SELECT id INTO v_revenue_id FROM accounts WHERE slug = 'sales_revenue';
    IF v_revenue_id IS NULL THEN
        SELECT id INTO v_revenue_id FROM accounts WHERE code = '4000';
    END IF;

    -- 3. Safety Check
    IF v_party_account_id IS NULL OR v_revenue_id IS NULL THEN
        RAISE EXCEPTION 'COMPLIANCE ERROR: Required control accounts (Accounts Receivable or Revenue) are missing.';
    END IF;
    
    -- INSERT FLOW
    IF TG_OP = 'INSERT' THEN
        SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
        VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_party_account_id, NEW.party_id, NEW.total_amount, 0, 'Sale to ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
        VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sales Revenue', NEW.quantity, NEW.rate_per_unit);

        PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'OUT');

        RETURN NEW;
    END IF;

    -- DELETE FLOW
    IF TG_OP = 'DELETE' THEN
        PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'IN');
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        RETURN OLD;
    END IF;

    -- UPDATE FLOW
    IF TG_OP = 'UPDATE' THEN
        -- Smart Edit bypass for stock
        IF NEW.fuel_type_id IS DISTINCT FROM OLD.fuel_type_id THEN
            -- Full return of old, deduct new
            PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'IN');
            PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'OUT');
        ELSIF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
            v_delta := NEW.quantity - OLD.quantity;
            IF v_delta > 0 THEN
                -- Sold more, deduct from stock
                PERFORM public.update_stock_quantity(NEW.fuel_type_id, v_delta, 'OUT');
            ELSIF v_delta < 0 THEN
                -- Sold less, return to stock
                PERFORM public.update_stock_quantity(NEW.fuel_type_id, abs(v_delta), 'IN');
            END IF;
        END IF;

        -- Handle Ledger Rebuild (on any significant changes including fuel type)
        IF NEW.total_amount IS DISTINCT FROM OLD.total_amount 
           OR NEW.rate_per_unit IS DISTINCT FROM OLD.rate_per_unit
           OR NEW.quantity IS DISTINCT FROM OLD.quantity
           OR NEW.sale_date IS DISTINCT FROM OLD.sale_date
           OR NEW.party_id IS DISTINCT FROM OLD.party_id
           OR NEW.fuel_type_id IS DISTINCT FROM OLD.fuel_type_id THEN
            
            SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;
            
            DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
            VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_party_account_id, NEW.party_id, NEW.total_amount, 0, 'Sale to ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
            VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sales Revenue', NEW.quantity, NEW.rate_per_unit);
        ELSE
            -- Narration only update
            UPDATE public.ledger_entries 
            SET narration = COALESCE(NEW.notes, 'Sale to ' || (SELECT name FROM parties WHERE id = NEW.party_id))
            WHERE voucher_no = NEW.voucher_no AND account_id = v_party_account_id;
        END IF;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 4. DROP AND RE-ATTACH MAIN TRANSACTION LEDGER SYNC TRIGGERS
-- ============================================================================
-- Ensure the triggers on purchases and sales are explicitly dropped and recreated
-- so they definitely run our updated proc_purchase_ledger_strict and proc_sale_ledger_strict functions.
DROP TRIGGER IF EXISTS trg_purchase_ledger_strict ON public.purchases;
CREATE TRIGGER trg_purchase_ledger_strict
AFTER INSERT OR UPDATE OR DELETE ON public.purchases
FOR EACH ROW EXECUTE FUNCTION public.proc_purchase_ledger_strict();

DROP TRIGGER IF EXISTS trg_sale_ledger_strict ON public.sales;
CREATE TRIGGER trg_sale_ledger_strict
AFTER INSERT OR UPDATE OR DELETE ON public.sales
FOR EACH ROW EXECUTE FUNCTION public.proc_sale_ledger_strict();

-- ============================================================================
-- 5. RELOAD SCHEMA CACHE
-- ============================================================================
NOTIFY pgrst, 'reload schema';

COMMIT;

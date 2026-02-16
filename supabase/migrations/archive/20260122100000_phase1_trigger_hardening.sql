-- PHASE 1: TRIGGER & DATA INTEGRITY HARDENING (SEV-0) - FINAL GOLD
-- -----------------------------------------------------------------
-- This migration REMOVES all legacy triggers and installs a ROBUST, MUNSHI-COMPLIANT accounting engine.
-- Core Principles:
-- 1. All Parties are treated equally (Control Account 1100 - Party Ledger).
-- 2. Sales Update Stock Quantity immediately.
-- 3. Purchases Update Stock Quantity immediately.
-- 4. Periodic Inventory Model (COGS calculated at report time, not per voucher).
-- 5. Strict Validated Deduplication.
-- 6. NEGATIVE STOCK PROTECTION.
-- 7. DELETE SAFETY (Reverses Stock).

BEGIN;

--------------------------------------------------------------------------------
-- 1. NUCLEAR CLEANUP: DROP ALL LEGACY TRIGGERS
--------------------------------------------------------------------------------
-- Sales
DROP TRIGGER IF EXISTS trg_sale_ledger ON public.sales;
DROP TRIGGER IF EXISTS trigger_sale_ledger ON public.sales;
DROP TRIGGER IF EXISTS sale_ledger_trigger ON public.sales;
DROP TRIGGER IF EXISTS trg_ledger_sale ON public.sales;
DROP TRIGGER IF EXISTS trg_audit_sales ON public.sales;
DROP TRIGGER IF EXISTS trigger_sale_ledger_entries ON public.sales;
DROP TRIGGER IF EXISTS trigger_sale_inventory ON public.sales;
DROP TRIGGER IF EXISTS trg_sale_ledger_final ON public.sales;
DROP TRIGGER IF EXISTS trg_check_inventory ON public.sales;
DROP TRIGGER IF EXISTS trg_sale_stock_update ON public.sales; -- Future proofing
DROP TRIGGER IF EXISTS trg_sale_ledger_strict ON public.sales; -- Drop previous attempt
DROP TRIGGER IF EXISTS trg_sale_delete_cascade ON public.sales;

-- Purchases
DROP TRIGGER IF EXISTS trg_purchase_ledger ON public.purchases;
DROP TRIGGER IF EXISTS trigger_purchase_ledger ON public.purchases;
DROP TRIGGER IF EXISTS purchase_ledger_trigger ON public.purchases;
DROP TRIGGER IF EXISTS trg_audit_purchases ON public.purchases;
DROP TRIGGER IF EXISTS trigger_purchase_inventory ON public.purchases;
DROP TRIGGER IF EXISTS trigger_purchase_ledger_entries ON public.purchases;
DROP TRIGGER IF EXISTS trg_purchase_ledger_final ON public.purchases;
DROP TRIGGER IF EXISTS trg_purchase_ledger_strict ON public.purchases;
DROP TRIGGER IF EXISTS trg_purchase_delete_cascade ON public.purchases;

-- Payments
DROP TRIGGER IF EXISTS trg_payment_ledger ON public.payments;
DROP TRIGGER IF EXISTS trigger_payment_ledger ON public.payments;
DROP TRIGGER IF EXISTS payment_ledger_trigger ON public.payments;
DROP TRIGGER IF EXISTS trigger_payment_receipt_ledger_unified ON public.payments;
DROP TRIGGER IF EXISTS trigger_receipt_ledger ON public.payments;
DROP TRIGGER IF EXISTS trg_audit_payments ON public.payments;
DROP TRIGGER IF EXISTS trg_payment_ledger_final ON public.payments;
DROP TRIGGER IF EXISTS trg_payment_ledger_strict ON public.payments;
DROP TRIGGER IF EXISTS trg_payment_delete_cascade ON public.payments;

-- Sync
DROP TRIGGER IF EXISTS trg_sync_party_balance ON public.ledger_entries;
DROP TRIGGER IF EXISTS trg_sync_party_balance_strict ON public.ledger_entries;


--------------------------------------------------------------------------------
-- 2. HELPER: UPDATING STOCK QUANTITY (PHYSICAL ONLY) + SAFETY
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_stock_quantity(_fuel_type_id UUID, _quantity NUMERIC, _direction TEXT)
RETURNS VOID AS $$
DECLARE
    v_current_qty NUMERIC;
BEGIN
    -- _direction: 'IN' (Purchase/Return) or 'OUT' (Sale/Loss)
    
    -- Check Negative Stock Risk on OUT
    IF _direction = 'OUT' THEN
        SELECT quantity INTO v_current_qty FROM inventory WHERE fuel_type_id = _fuel_type_id;
        
        -- If no record or insufficient, block (unless we want to allow negative for correction, generally BLOCK)
        IF v_current_qty IS NULL OR (v_current_qty - _quantity) < 0 THEN
             RAISE EXCEPTION 'INVENTORY BLOCKED: Insufficient stock. Current: %, Requested: %', COALESCE(v_current_qty, 0), _quantity;
        END IF;

        UPDATE inventory 
        SET quantity = quantity - _quantity,
            last_updated = NOW()
        WHERE fuel_type_id = _fuel_type_id;
        
    ELSIF _direction = 'IN' THEN
        UPDATE inventory 
        SET quantity = quantity + _quantity,
            last_updated = NOW()
        WHERE fuel_type_id = _fuel_type_id;
    END IF;
    
    -- If no row exists (rare for sales, possible for first purchase), insert it
    IF NOT FOUND AND _direction = 'IN' THEN
        INSERT INTO inventory (fuel_type_id, quantity)
        VALUES (_fuel_type_id, _quantity);
    END IF;
END;
$$ LANGUAGE plpgsql;


--------------------------------------------------------------------------------
-- 3. DEFINE STRICT ACCOUNTING FUNCTIONS
--------------------------------------------------------------------------------

-- 3.a SALES LEDGER & STOCK
CREATE OR REPLACE FUNCTION public.proc_sale_ledger_strict()
RETURNS TRIGGER AS $$
DECLARE
    v_party_account_id UUID;
    v_revenue_id UUID;
    v_party_name TEXT;
BEGIN
    SELECT id INTO v_party_account_id FROM accounts WHERE code = '1100'; -- Unified Party Ledger
    SELECT id INTO v_revenue_id FROM accounts WHERE code = '4000';       -- Sales Revenue
    SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

    -- 1. GL ENTRIES
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_party_account_id, NEW.party_id, NEW.total_amount, 0, 'Sale to ' || v_party_name || ' (' || NEW.quantity || 'L @ ' || NEW.rate_per_unit || ')');

    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sales Revenue');

    -- 2. STOCK UPDATE
    PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'OUT');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- 3.b PURCHASE LEDGER & STOCK
CREATE OR REPLACE FUNCTION public.proc_purchase_ledger_strict()
RETURNS TRIGGER AS $$
DECLARE
    v_party_account_id UUID;
    v_purchase_account_id UUID;
    v_party_name TEXT;
BEGIN
    SELECT id INTO v_party_account_id FROM accounts WHERE code = '1100'; -- Unified Party Ledger
    -- Try to find Purchase Expense Account (5000), else fallback to Inventory (1200)
    SELECT id INTO v_purchase_account_id FROM accounts WHERE code = '5000';
    IF v_purchase_account_id IS NULL THEN
        SELECT id INTO v_purchase_account_id FROM accounts WHERE code = '1200';
    END IF;
    
    SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

    -- 1. GL ENTRIES
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_purchase_account_id, NULL, NEW.total_amount, 0, 'Purchase from ' || v_party_name || ' (' || NEW.quantity || 'L @ ' || NEW.rate_per_unit || ')');

    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_party_account_id, NEW.party_id, 0, NEW.total_amount, 'Credit Purchase - ' || v_party_name);

    -- 2. STOCK UPDATE
    PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'IN');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- 3.c PAYMENT LEDGER
CREATE OR REPLACE FUNCTION public.proc_payment_ledger_strict()
RETURNS TRIGGER AS $$
DECLARE
    v_cash_id UUID;
    v_party_account_id UUID;
BEGIN
    SELECT id INTO v_cash_id FROM accounts WHERE code = '1000';
    SELECT id INTO v_party_account_id FROM accounts WHERE code = '1100';

    IF NEW.payment_type = 'receipt' THEN
        -- WASOOLI: Dr Cash, Cr Party
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES 
        (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, NEW.amount, 0, 'Cash Received - ' || COALESCE(NEW.notes, '')),
        (NEW.voucher_no, 'payment', NEW.payment_date, v_party_account_id, NEW.party_id, 0, NEW.amount, 'Wasooli: ' || COALESCE(NEW.notes, ''));
    
    ELSE
        -- ADAIGI: Dr Party, Cr Cash
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES 
        (NEW.voucher_no, 'payment', NEW.payment_date, v_party_account_id, NEW.party_id, NEW.amount, 0, 'Payment: ' || COALESCE(NEW.notes, '')),
        (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, 0, NEW.amount, 'Cash Paid Out');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- 3.d CASCADE DELETE & STOCK REVERSAL TRIGGER
-- Safety: If a voucher is deleted, its ledger entries MUST die AND Stock must be reversed.
CREATE OR REPLACE FUNCTION public.proc_cascade_delete_ledger()
RETURNS TRIGGER AS $$
BEGIN
    -- 1. Reverse Stock
    IF TG_TABLE_NAME = 'sales' THEN
        -- Delete Sale = Cancellation of OUT = Put it back IN
        PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'IN');
    ELSIF TG_TABLE_NAME = 'purchases' THEN
        -- Delete Purchase = Cancellation of IN = Take it OUT
        PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'OUT');
    END IF;

    -- 2. Delete Ledger Entries
    DELETE FROM ledger_entries WHERE voucher_no = OLD.voucher_no;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;


--------------------------------------------------------------------------------
-- 4. BIND TRIGGERS
--------------------------------------------------------------------------------

CREATE TRIGGER trg_sale_ledger_strict
AFTER INSERT ON public.sales
FOR EACH ROW EXECUTE FUNCTION proc_sale_ledger_strict();

CREATE TRIGGER trg_sale_delete_cascade
BEFORE DELETE ON public.sales
FOR EACH ROW EXECUTE FUNCTION proc_cascade_delete_ledger();

CREATE TRIGGER trg_purchase_ledger_strict
AFTER INSERT ON public.purchases
FOR EACH ROW EXECUTE FUNCTION proc_purchase_ledger_strict();

CREATE TRIGGER trg_purchase_delete_cascade
BEFORE DELETE ON public.purchases
FOR EACH ROW EXECUTE FUNCTION proc_cascade_delete_ledger();

CREATE TRIGGER trg_payment_ledger_strict
AFTER INSERT ON public.payments
FOR EACH ROW EXECUTE FUNCTION proc_payment_ledger_strict();

CREATE TRIGGER trg_payment_delete_cascade
BEFORE DELETE ON public.payments
FOR EACH ROW EXECUTE FUNCTION proc_cascade_delete_ledger();


--------------------------------------------------------------------------------
-- 5. BALANCE SYNC (Optimized)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_party_balance_strict()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        IF NEW.party_id IS NOT NULL THEN
            UPDATE parties 
            SET current_balance = (
                SELECT COALESCE(SUM(debit_amount - credit_amount), 0) 
                FROM ledger_entries 
                WHERE party_id = NEW.party_id
            ) 
            WHERE id = NEW.party_id;
        END IF;
    END IF;
    
    IF (TG_OP = 'DELETE') THEN
        IF OLD.party_id IS NOT NULL THEN
            UPDATE parties 
            SET current_balance = (
                SELECT COALESCE(SUM(debit_amount - credit_amount), 0) 
                FROM ledger_entries 
                WHERE party_id = OLD.party_id
            ) 
            WHERE id = OLD.party_id;
        END IF;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_party_balance_strict
AFTER INSERT OR UPDATE OR DELETE ON public.ledger_entries
FOR EACH ROW EXECUTE FUNCTION sync_party_balance_strict();


--------------------------------------------------------------------------------
-- 6. SAFE DATA DEDUPLICATION
--------------------------------------------------------------------------------
-- Strictly delete duplicates only if they match completely on accounting data
DELETE FROM ledger_entries a 
USING ledger_entries b 
WHERE a.id > b.id 
  AND a.voucher_no = b.voucher_no 
  AND a.account_id = b.account_id 
  AND a.debit_amount = b.debit_amount
  AND a.credit_amount = b.credit_amount
  AND COALESCE(a.party_id, '00000000-0000-0000-0000-000000000000'::uuid) = COALESCE(b.party_id, '00000000-0000-0000-0000-000000000000'::uuid);

-- Final Sync
UPDATE parties p
SET current_balance = (
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    FROM ledger_entries 
    WHERE party_id = p.id
);

COMMIT;

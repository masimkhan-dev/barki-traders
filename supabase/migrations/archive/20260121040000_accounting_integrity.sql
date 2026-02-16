-- MASTER ACCOUNTING & INVENTORY INTEGRITY FIX
-- This script fixes the "Inverted Balances" and "Negative Stock" logic by harmonizing triggers.
BEGIN;

-- 1. UTILITY: BLOCK NEGATIVE STOCK (The "Real Financial Risk" Fix)
-- This trigger prevents any sale that would result in negative stock.
CREATE OR REPLACE FUNCTION check_inventory_levels()
RETURNS TRIGGER AS $$
DECLARE
    v_current_stock NUMERIC;
BEGIN
    -- Calculate current stock from transactions
    SELECT 
        COALESCE((SELECT SUM(quantity) FROM purchases WHERE fuel_type_id = NEW.fuel_type_id), 0) -
        COALESCE((SELECT SUM(quantity) FROM sales WHERE fuel_type_id = NEW.fuel_type_id AND id != NEW.id), 0)
    INTO v_current_stock;

    IF (v_current_stock - NEW.quantity) < 0 THEN
        RAISE EXCEPTION 'INVENTORY ERROR: Cannot sell % Liters. Current stock is only % Liters. Negative stock is forbidden.', NEW.quantity, v_current_stock;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_inventory ON sales;
CREATE TRIGGER trg_check_inventory
BEFORE INSERT OR UPDATE ON sales
FOR EACH ROW EXECUTE FUNCTION check_inventory_levels();


-- 2. HARMONIZED SALES TRIGGER: Unified Party Support
CREATE OR REPLACE FUNCTION public.create_sale_ledger_entries()
RETURNS TRIGGER AS $$
DECLARE
    v_receivable_id UUID;
    v_revenue_id UUID;
    v_inventory_id UUID;
    v_cogs_id UUID;
    v_party_name TEXT;
BEGIN
    SELECT id INTO v_receivable_id FROM accounts WHERE code = '1100';
    SELECT id INTO v_revenue_id FROM accounts WHERE code = '4000';
    SELECT id INTO v_inventory_id FROM accounts WHERE code = '1200';
    SELECT id INTO v_cogs_id FROM accounts WHERE code = '5000';
    SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

    -- A. REVENUE & RECEIVABLE
    -- Debit: Accounts Receivable (1100), Credit: Sales Revenue (4000)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES 
    (NEW.voucher_no, 'sale', NEW.sale_date, v_receivable_id, NEW.party_id, NEW.total_amount, 0, 'Sales to ' || v_party_name || CASE WHEN NEW.notes IS NOT NULL THEN ' - ' || NEW.notes ELSE '' END),
    (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Sales Revenue - ' || v_party_name);

    -- B. INVENTORY & COGS (Simplification: Using zero until cost tracking is robust, or standard cost)
    -- This ensures we don't crash if inventory table is missing/buggy.
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- 3. HARMONIZED PURCHASE TRIGGER: Unified Party Support
CREATE OR REPLACE FUNCTION public.create_purchase_ledger_entries()
RETURNS TRIGGER AS $$
DECLARE
    v_payable_id UUID;
    v_inventory_id UUID;
    v_party_name TEXT;
BEGIN
    SELECT id INTO v_payable_id FROM accounts WHERE code = '2000';
    SELECT id INTO v_inventory_id FROM accounts WHERE code = '1200';
    SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

    -- Debit: Fuel Inventory (1200), Credit: Accounts Payable (2000)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES 
    (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_id, NULL, NEW.total_amount, 0, 'Purchase from ' || v_party_name),
    (NEW.voucher_no, 'purchase', NEW.purchase_date, v_payable_id, NEW.party_id, 0, NEW.total_amount, 'Credit Purchase from ' || v_party_name);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- 4. HARMONIZED PAYMENT/RECEIPT TRIGGER
CREATE OR REPLACE FUNCTION public.create_payment_ledger_entries_unified()
RETURNS TRIGGER AS $$
DECLARE
    v_receivable_id UUID;
    v_payable_id UUID;
    v_cash_id UUID;
    v_party_type TEXT;
    v_gl_account_id UUID;
BEGIN
    SELECT id INTO v_receivable_id FROM accounts WHERE code = '1100';
    SELECT id INTO v_payable_id FROM accounts WHERE code = '2000';
    SELECT id INTO v_cash_id FROM accounts WHERE code = '1000';
    SELECT type INTO v_party_type FROM parties WHERE id = NEW.party_id;

    -- Determine which GL control account to hit
    v_gl_account_id := CASE WHEN v_party_type = 'supplier' THEN v_payable_id ELSE v_receivable_id END;

    IF NEW.payment_type = 'receipt' THEN
        -- Wasooli (Money In): Debit Cash (1000), Credit Party (via Control GL)
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES 
        (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, NEW.amount, 0, 'Receipt from Party - ' || NEW.notes),
        (NEW.voucher_no, 'payment', NEW.payment_date, v_gl_account_id, NEW.party_id, 0, NEW.amount, 'Credit to Party Ledger');
    ELSE
        -- Adaigi (Money Out): Debit Party (via Control GL), Credit Cash (1000)
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES 
        (NEW.voucher_no, 'payment', NEW.payment_date, v_gl_account_id, NEW.party_id, NEW.amount, 0, 'Payment to Party - ' || NEW.notes),
        (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, 0, NEW.amount, 'Debit from Cash/Bank');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- 5. RE-REGISTER ALL MASTER TRIGGERS
DROP TRIGGER IF EXISTS trigger_sale_ledger ON sales;
CREATE TRIGGER trigger_sale_ledger AFTER INSERT ON sales FOR EACH ROW EXECUTE FUNCTION create_sale_ledger_entries();

DROP TRIGGER IF EXISTS trigger_purchase_ledger ON purchases;
CREATE TRIGGER trigger_purchase_ledger AFTER INSERT ON purchases FOR EACH ROW EXECUTE FUNCTION create_purchase_ledger_entries();

DROP TRIGGER IF EXISTS trigger_payment_ledger ON payments;
DROP TRIGGER IF EXISTS trigger_receipt_ledger ON payments;
CREATE TRIGGER trigger_payment_receipt_ledger_unified AFTER INSERT ON payments FOR EACH ROW EXECUTE FUNCTION create_payment_ledger_entries_unified();


-- 6. CORRECTIVE DATA SYNC (Force current_balance to match ledger)
-- This fixes any "Inverted Balances" caused by old stale entries.
UPDATE parties p
SET current_balance = (
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    FROM ledger_entries 
    WHERE party_id = p.id
);

COMMIT;
NOTIFY pgrst, 'reload config';

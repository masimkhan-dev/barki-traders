-- MASTER REPAIR V13: THE TRIPLING EFFECT FIX
-- Focus: Destroying redundant triggers and ensuring exactly ONE ledger post per transaction.

BEGIN;

-- 1. NUKE ALL KNOWN TRIGGER NAMES (From all previous migrations)
-- Sales Triggers
DROP TRIGGER IF EXISTS trg_sale_ledger ON public.sales;
DROP TRIGGER IF EXISTS trigger_sale_ledger ON public.sales;
DROP TRIGGER IF EXISTS sale_ledger_trigger ON public.sales;
DROP TRIGGER IF EXISTS trg_ledger_sale ON public.sales;
DROP TRIGGER IF EXISTS trg_audit_sales ON public.sales;
DROP TRIGGER IF EXISTS trigger_sale_ledger_entries ON public.sales;
DROP TRIGGER IF EXISTS trigger_sale_inventory ON public.sales;
DROP TRIGGER IF EXISTS trigger_sale_ledger ON public.sales;

-- Purchase Triggers
DROP TRIGGER IF EXISTS trg_purchase_ledger ON public.purchases;
DROP TRIGGER IF EXISTS trigger_purchase_ledger ON public.purchases;
DROP TRIGGER IF EXISTS purchase_ledger_trigger ON public.purchases;
DROP TRIGGER IF EXISTS trg_audit_purchases ON public.purchases;
DROP TRIGGER IF EXISTS trigger_purchase_inventory ON public.purchases;
DROP TRIGGER IF EXISTS trigger_purchase_ledger ON public.purchases;

-- Payment Triggers
DROP TRIGGER IF EXISTS trg_payment_ledger ON public.payments;
DROP TRIGGER IF EXISTS trigger_payment_ledger ON public.payments;
DROP TRIGGER IF EXISTS payment_ledger_trigger ON public.payments;
DROP TRIGGER IF EXISTS trigger_payment_receipt_ledger_unified ON public.payments;
DROP TRIGGER IF EXISTS trigger_receipt_ledger ON public.payments;
DROP TRIGGER IF EXISTS trg_audit_payments ON public.payments;
DROP TRIGGER IF EXISTS trigger_payment_ledger ON public.payments;
DROP TRIGGER IF EXISTS trigger_receipt_ledger ON public.payments;

-- 2. RE-DEFINE CLEAN LEDGER FUNCTIONS

-- 2a. SALE LEDGER (Sadiq's 56k stays 56k)
CREATE OR REPLACE FUNCTION public.proc_sale_ledger_v13()
RETURNS TRIGGER AS $$
DECLARE v_receivable_id UUID; v_revenue_id UUID; v_party_name TEXT;
BEGIN
    SELECT id INTO v_receivable_id FROM accounts WHERE code = '1100'; -- Accounts Receivable
    SELECT id INTO v_revenue_id FROM accounts WHERE code = '4000';    -- Sales Revenue
    SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

    -- Debit: Customer (Increases what they owe)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_receivable_id, NEW.party_id, NEW.total_amount, 0, 'Sale: ' || v_party_name || ' (' || NEW.quantity || 'L)');

    -- Credit: Sales Revenue
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Sales Revenue - ' || v_party_name);

    RETURN NEW;
END; $$ LANGUAGE plpgsql;

-- 2b. PURCHASE LEDGER
CREATE OR REPLACE FUNCTION public.proc_purchase_ledger_v13()
RETURNS TRIGGER AS $$
DECLARE v_payable_id UUID; v_inventory_id UUID; v_party_name TEXT;
BEGIN
    SELECT id INTO v_payable_id FROM accounts WHERE code = '2000';   -- Accounts Payable
    SELECT id INTO v_inventory_id FROM accounts WHERE code = '1200'; -- Fuel Inventory
    SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

    -- Debit: Inventory (We got fuel)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_id, NULL, NEW.total_amount, 0, 'Purchase: ' || v_party_name || ' (' || NEW.quantity || 'L)');

    -- Credit: Supplier (We owe them)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_payable_id, NEW.party_id, 0, NEW.total_amount, 'Credit Purchase from ' || v_party_name);

    RETURN NEW;
END; $$ LANGUAGE plpgsql;

-- 2c. PAYMENT LEDGER
CREATE OR REPLACE FUNCTION public.proc_payment_ledger_v13()
RETURNS TRIGGER AS $$
DECLARE v_cash_id UUID; v_gl_id UUID; v_party_type TEXT;
BEGIN
    SELECT id INTO v_cash_id FROM accounts WHERE code = '1000';
    SELECT type INTO v_party_type FROM parties WHERE id = NEW.party_id;
    v_gl_id := CASE WHEN v_party_type = 'supplier' THEN (SELECT id FROM accounts WHERE code = '2000') ELSE (SELECT id FROM accounts WHERE code = '1100') END;

    IF NEW.payment_type = 'receipt' THEN
        -- Wasooli: Dr Cash, Cr Party (Reduces Customer Balance)
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, NEW.amount, 0, 'Cash Received - ' || NEW.notes),
               (NEW.voucher_no, 'payment', NEW.payment_date, v_gl_id, NEW.party_id, 0, NEW.amount, 'Wasooli From Party');
    ELSE
        -- Adaigi: Dr Party (Reduces Supplier Payable), Cr Cash
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES (NEW.voucher_no, 'payment', NEW.payment_date, v_gl_id, NEW.party_id, NEW.amount, 0, 'Payment To Party - ' || NEW.notes),
               (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, 0, NEW.amount, 'Cash Paid Out');
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;


-- 3. REGISTER THE "ONLY" TRIGGERS
CREATE TRIGGER trg_sale_ledger_final AFTER INSERT ON public.sales FOR EACH ROW EXECUTE FUNCTION proc_sale_ledger_v13();
CREATE TRIGGER trg_purchase_ledger_final AFTER INSERT ON public.purchases FOR EACH ROW EXECUTE FUNCTION proc_purchase_ledger_v13();
CREATE TRIGGER trg_payment_ledger_final AFTER INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION proc_payment_ledger_v13();

-- 4. THE AUTO-BALANCE SYNC (This is the most reliable way)
-- Whenever ledger changes, party balance MUST refresh from SUM(entries)
CREATE OR REPLACE FUNCTION public.sync_party_balance_v13()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        UPDATE parties SET current_balance = (SELECT COALESCE(SUM(debit_amount - credit_amount), 0) FROM ledger_entries WHERE party_id = NEW.party_id) WHERE id = NEW.party_id;
    END IF;
    IF (TG_OP = 'DELETE') THEN
        UPDATE parties SET current_balance = (SELECT COALESCE(SUM(debit_amount - credit_amount), 0) FROM ledger_entries WHERE party_id = OLD.party_id) WHERE id = OLD.party_id;
    END IF;
    RETURN NULL;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_party_balance ON ledger_entries;
CREATE TRIGGER trg_sync_party_balance AFTER INSERT OR UPDATE OR DELETE ON ledger_entries FOR EACH ROW EXECUTE FUNCTION sync_party_balance_v13();


-- 5. FINAL RECALCULATION (Fix the "168,000" damage)
-- Note: If ledger has triple entries, we must delete them.
-- Strategy: If multiple ledger rows exist for same voucher and account, keep only one.
DELETE FROM ledger_entries a 
USING ledger_entries b 
WHERE a.id > b.id 
  AND a.voucher_no = b.voucher_no 
  AND a.account_id = b.account_id 
  AND COALESCE(a.party_id, '00000000-0000-0000-0000-000000000000'::uuid) = COALESCE(b.party_id, '00000000-0000-0000-0000-000000000000'::uuid);

-- Now sync party balances based on the corrected ledger
UPDATE parties p
SET current_balance = (
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    FROM ledger_entries 
    WHERE party_id = p.id
) + opening_balance; -- Added opening_balance to the sum

COMMIT;
NOTIFY pgrst, 'reload config';

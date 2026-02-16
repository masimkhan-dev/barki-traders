-- ========================================
-- CRITICAL ACCOUNTING FIXES
-- Migration: 20260114000001_accounting_fixes.sql
-- ========================================
-- This migration fixes critical accounting bugs:
-- 1. Adds Advance Accounts (Customer & Supplier)
-- 2. Fixes Receipt trigger to handle overpayments
-- 3. Fixes Payment trigger to handle overpayments
-- 4. Adds COGS validation to prevent zero-cost sales
-- ========================================

-- PART 1: Add Missing Advance Accounts
-- ========================================

INSERT INTO public.accounts (code, name, account_type, is_system, is_active) VALUES
('1110', 'Supplier Advances', 'asset', true, true),
('2100', 'Customer Advances', 'liability', true, true)
ON CONFLICT (code) DO NOTHING;

-- PART 2: Fix Receipt Trigger (Customer Payments)
-- ========================================
-- Handles overpayments by posting excess to Customer Advance (Liability)

CREATE OR REPLACE FUNCTION public.create_receipt_ledger_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    cash_account_id UUID;
    bank_account_id UUID;
    receivable_account_id UUID;
    customer_advance_account_id UUID;
    target_account_id UUID;
    customer_ar_balance NUMERIC;
    receivable_portion NUMERIC;
    advance_portion NUMERIC;
BEGIN
    -- Get account IDs
    SELECT id INTO cash_account_id FROM accounts WHERE code = '1000';
    SELECT id INTO bank_account_id FROM accounts WHERE code = '1010';
    SELECT id INTO receivable_account_id FROM accounts WHERE code = '1100';
    SELECT id INTO customer_advance_account_id FROM accounts WHERE code = '2100';
    
    -- Determine target account based on payment method
    IF NEW.payment_method = 'Cash' THEN
        target_account_id := cash_account_id;
    ELSE
        target_account_id := bank_account_id;
    END IF;
    
    -- Only process receipts
    IF NEW.payment_type = 'receipt' THEN
        -- Calculate customer's AR balance
        -- AR Balance = Opening Balance + Sum(Dr) - Sum(Cr) for this customer
        SELECT COALESCE(c.opening_balance, 0) +
               COALESCE((SELECT SUM(debit_amount - credit_amount) 
                        FROM ledger_entries 
                        WHERE account_id = receivable_account_id 
                        AND reference_id = NEW.party_id
                        AND reference_type IN ('sale', 'payment')), 0)
        INTO customer_ar_balance
        FROM customers c
        WHERE c.id = NEW.party_id;
        
        -- Determine how to split the receipt
        IF NEW.amount <= customer_ar_balance THEN
            -- Normal case: Receipt ≤ AR Balance
            receivable_portion := NEW.amount;
            advance_portion := 0;
        ELSE
            -- Overpayment: Receipt > AR Balance
            receivable_portion := customer_ar_balance;
            advance_portion := NEW.amount - customer_ar_balance;
        END IF;
        
        -- Post receivable portion (if any)
        IF receivable_portion > 0 THEN
            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
            VALUES 
                (NEW.voucher_no, 'receipt', NEW.payment_date, target_account_id, receivable_portion, 0, 'payment', NEW.id, 'Receipt from customer (AR settlement)', NEW.created_by),
                (NEW.voucher_no, 'receipt', NEW.payment_date, receivable_account_id, 0, receivable_portion, 'payment', NEW.id, 'Customer payment received', NEW.created_by);
        END IF;
        
        -- Post advance portion (if any)
        IF advance_portion > 0 THEN
            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
            VALUES 
                (NEW.voucher_no, 'receipt', NEW.payment_date, target_account_id, advance_portion, 0, 'payment', NEW.id, 'Receipt from customer (Advance)', NEW.created_by),
                (NEW.voucher_no, 'receipt', NEW.payment_date, customer_advance_account_id, 0, advance_portion, 'payment', NEW.id, 'Customer advance received', NEW.created_by);
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

-- PART 3: Fix Payment Trigger (Supplier Payments)
-- ========================================
-- Handles overpayments by posting excess to Supplier Advance (Asset)

CREATE OR REPLACE FUNCTION public.create_payment_ledger_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    cash_account_id UUID;
    bank_account_id UUID;
    payable_account_id UUID;
    supplier_advance_account_id UUID;
    source_account_id UUID;
    supplier_ap_balance NUMERIC;
    payable_portion NUMERIC;
    advance_portion NUMERIC;
BEGIN
    -- Get account IDs
    SELECT id INTO cash_account_id FROM accounts WHERE code = '1000';
    SELECT id INTO bank_account_id FROM accounts WHERE code = '1010';
    SELECT id INTO payable_account_id FROM accounts WHERE code = '2000';
    SELECT id INTO supplier_advance_account_id FROM accounts WHERE code = '1110';
    
    -- Determine source account based on payment method
    IF NEW.payment_method = 'Cash' THEN
        source_account_id := cash_account_id;
    ELSE
        source_account_id := bank_account_id;
    END IF;
    
    -- Only process payments
    IF NEW.payment_type = 'payment' THEN
        -- Calculate supplier's AP balance
        -- AP Balance (liability) = Opening Balance + Sum(Cr) - Sum(Dr) for this supplier
        SELECT COALESCE(s.opening_balance, 0) +
               COALESCE((SELECT SUM(credit_amount - debit_amount) 
                        FROM ledger_entries 
                        WHERE account_id = payable_account_id 
                        AND reference_id = NEW.party_id
                        AND reference_type IN ('purchase', 'payment')), 0)
        INTO supplier_ap_balance
        FROM suppliers s
        WHERE s.id = NEW.party_id;
        
        -- Determine how to split the payment
        IF NEW.amount <= supplier_ap_balance THEN
            -- Normal case: Payment ≤ AP Balance
            payable_portion := NEW.amount;
            advance_portion := 0;
        ELSE
            -- Overpayment: Payment > AP Balance
            payable_portion := supplier_ap_balance;
            advance_portion := NEW.amount - supplier_ap_balance;
        END IF;
        
        -- Post payable portion (if any)
        IF payable_portion > 0 THEN
            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
            VALUES 
                (NEW.voucher_no, 'payment', NEW.payment_date, payable_account_id, payable_portion, 0, 'payment', NEW.id, 'Payment to supplier (AP settlement)', NEW.created_by),
                (NEW.voucher_no, 'payment', NEW.payment_date, source_account_id, 0, payable_portion, 'payment', NEW.id, 'Supplier payment made', NEW.created_by);
        END IF;
        
        -- Post advance portion (if any)
        IF advance_portion > 0 THEN
            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
            VALUES 
                (NEW.voucher_no, 'payment', NEW.payment_date, supplier_advance_account_id, advance_portion, 0, 'payment', NEW.id, 'Advance to supplier', NEW.created_by),
                (NEW.voucher_no, 'payment', NEW.payment_date, source_account_id, 0, advance_portion, 'payment', NEW.id, 'Supplier advance paid', NEW.created_by);
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

-- PART 4: Fix Sales Trigger - Add COGS Validation
-- ========================================
-- Prevents sales when COGS would be zero (no inventory cost available)

CREATE OR REPLACE FUNCTION public.create_sale_ledger_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    cash_account_id UUID;
    receivable_account_id UUID;
    revenue_account_id UUID;
    inventory_account_id UUID;
    cogs_account_id UUID;
    cogs_amount NUMERIC;
    current_avg_cost NUMERIC;
BEGIN
    -- Get account IDs
    SELECT id INTO cash_account_id FROM accounts WHERE code = '1000';
    SELECT id INTO receivable_account_id FROM accounts WHERE code = '1100';
    SELECT id INTO revenue_account_id FROM accounts WHERE code = '4000';
    SELECT id INTO inventory_account_id FROM accounts WHERE code = '1200';
    SELECT id INTO cogs_account_id FROM accounts WHERE code = '5000';
    
    -- Calculate COGS (Cost = Quantity * Weighted Average Cost)
    SELECT avg_cost INTO current_avg_cost FROM inventory WHERE fuel_type_id = NEW.fuel_type_id;
    
    -- CRITICAL VALIDATION: Prevent sale if no cost basis exists
    IF current_avg_cost IS NULL OR current_avg_cost = 0 THEN
        RAISE EXCEPTION 'Cannot sell inventory with zero or null cost. Purchase inventory first for fuel_type_id: %', NEW.fuel_type_id;
    END IF;
    
    cogs_amount := NEW.quantity * current_avg_cost;

    -- 1. Revenue Entry
    IF NEW.is_credit THEN
        -- Credit Sale: Dr Accounts Receivable, Cr Sales Revenue
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, receivable_account_id, NEW.total_amount, 0, 'sale', NEW.id, 'Credit sale to customer', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, revenue_account_id, 0, NEW.total_amount, 'sale', NEW.id, 'Credit sale revenue', NEW.created_by);
    ELSE
        -- Cash Sale: Dr Cash, Cr Sales Revenue
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, cash_account_id, NEW.total_amount, 0, 'sale', NEW.id, 'Cash sale', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, revenue_account_id, 0, NEW.total_amount, 'sale', NEW.id, 'Cash sale revenue', NEW.created_by);
    END IF;

    -- 2. Inventory/COGS Entry (Perpetual Inventory)
    -- Dr Cost of Goods Sold (Expense), Cr Fuel Inventory (Asset)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
    VALUES 
        (NEW.voucher_no, 'sale', NEW.sale_date, cogs_account_id, cogs_amount, 0, 'sale', NEW.id, 'Cost of goods sold', NEW.created_by),
        (NEW.voucher_no, 'sale', NEW.sale_date, inventory_account_id, 0, cogs_amount, 'sale', NEW.id, 'Inventory reduction', NEW.created_by);
    
    RETURN NEW;
END;
$$;

-- PART 5: Re-register All Triggers
-- ========================================

-- Sales trigger
DROP TRIGGER IF EXISTS trigger_sale_ledger ON sales;
CREATE TRIGGER trigger_sale_ledger
    AFTER INSERT ON sales
    FOR EACH ROW
    EXECUTE FUNCTION create_sale_ledger_entries();

-- Receipt trigger  
DROP TRIGGER IF EXISTS trigger_receipt_ledger ON payments;
CREATE TRIGGER trigger_receipt_ledger
    AFTER INSERT ON payments
    FOR EACH ROW
    WHEN (NEW.payment_type = 'receipt')
    EXECUTE FUNCTION create_receipt_ledger_entries();

-- Payment trigger
DROP TRIGGER IF EXISTS trigger_payment_ledger ON payments;
CREATE TRIGGER trigger_payment_ledger
    AFTER INSERT ON payments
    FOR EACH ROW
    WHEN (NEW.payment_type = 'payment')
    EXECUTE FUNCTION create_payment_ledger_entries();

-- ========================================
-- END OF MIGRATION
-- ========================================

-- Create triggers to post ledger entries for all transactions
-- This ensures proper double-entry accounting

-- Function to create ledger entries for SALES
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
    SELECT id INTO cash_account_id FROM accounts WHERE code = '1000'; -- Cash
    SELECT id INTO receivable_account_id FROM accounts WHERE code = '1100'; -- Accounts Receivable
    SELECT id INTO revenue_account_id FROM accounts WHERE code = '4000'; -- Sales Revenue
    SELECT id INTO inventory_account_id FROM accounts WHERE code = '1200'; -- Fuel Inventory
    SELECT id INTO cogs_account_id FROM accounts WHERE code = '5000'; -- Cost of Goods Sold
    
    -- Calculate COGS (Cost = Quantity * Weighted Average Cost)
    SELECT avg_cost INTO current_avg_cost FROM inventory WHERE fuel_type_id = NEW.fuel_type_id;
    cogs_amount := NEW.quantity * COALESCE(current_avg_cost, 0);

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

    -- 2. inventory/COGS Entry (Perpetual Inventory)
    -- Dr Cost of Goods Sold (Expense), Cr Fuel Inventory (Asset)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
    VALUES 
        (NEW.voucher_no, 'sale', NEW.sale_date, cogs_account_id, cogs_amount, 0, 'sale', NEW.id, 'Cost of goods sold', NEW.created_by),
        (NEW.voucher_no, 'sale', NEW.sale_date, inventory_account_id, 0, cogs_amount, 'sale', NEW.id, 'Inventory reduction', NEW.created_by);
    
    RETURN NEW;
END;
$$;

-- Function to create ledger entries for PURCHASES
CREATE OR REPLACE FUNCTION public.create_purchase_ledger_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    inventory_account_id UUID;
    payable_account_id UUID;
BEGIN
    -- Get account IDs
    SELECT id INTO inventory_account_id FROM accounts WHERE code = '1200'; -- Fuel Inventory (Asset)
    SELECT id INTO payable_account_id FROM accounts WHERE code = '2000'; -- Accounts Payable
    
    -- Purchase: Dr Fuel Inventory (Asset), Cr Accounts Payable (Liability)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
    VALUES 
        (NEW.voucher_no, 'purchase', NEW.purchase_date, inventory_account_id, NEW.total_amount, 0, 'purchase', NEW.id, 'Fuel purchase - Inventory increase', NEW.created_by),
        (NEW.voucher_no, 'purchase', NEW.purchase_date, payable_account_id, 0, NEW.total_amount, 'purchase', NEW.id, 'Supplier payable', NEW.created_by);
    
    RETURN NEW;
END;
$$;

-- Function to create ledger entries for RECEIPTS (money from customers)
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
    target_account_id UUID;
BEGIN
    -- Get account IDs
    SELECT id INTO cash_account_id FROM accounts WHERE code = '1000'; -- Cash
    SELECT id INTO bank_account_id FROM accounts WHERE code = '1010'; -- Bank Account
    SELECT id INTO receivable_account_id FROM accounts WHERE code = '1100'; -- Accounts Receivable
    
    -- Determine target account based on payment method
    IF NEW.payment_method = 'Cash' THEN
        target_account_id := cash_account_id;
    ELSE
        target_account_id := bank_account_id;
    END IF;
    
    -- Only process receipts (not payments)
    IF NEW.payment_type = 'receipt' THEN
        -- Receipt: Dr Cash/Bank (money in), Cr Accounts Receivable (customer pays debt)
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'receipt', NEW.payment_date, target_account_id, NEW.amount, 0, 'payment', NEW.id, 'Receipt from customer', NEW.created_by),
            (NEW.voucher_no, 'receipt', NEW.payment_date, receivable_account_id, 0, NEW.amount, 'payment', NEW.id, 'Customer payment received', NEW.created_by);
    END IF;
    
    RETURN NEW;
END;
$$;

-- Function to create ledger entries for PAYMENTS (to suppliers)
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
    source_account_id UUID;
BEGIN
    -- Get account IDs
    SELECT id INTO cash_account_id FROM accounts WHERE code = '1000'; -- Cash
    SELECT id INTO bank_account_id FROM accounts WHERE code = '1010'; -- Bank Account
    SELECT id INTO payable_account_id FROM accounts WHERE code = '2000'; -- Accounts Payable
    
    -- Determine source account based on payment method
    IF NEW.payment_method = 'Cash' THEN
        source_account_id := cash_account_id;
    ELSE
        source_account_id := bank_account_id;
    END IF;
    
    -- Only process payments (not receipts)
    IF NEW.payment_type = 'payment' THEN
        -- Payment: Dr Accounts Payable (reduce debt), Cr Cash/Bank (money out)
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'payment', NEW.payment_date, payable_account_id, NEW.amount, 0, 'payment', NEW.id, 'Payment to supplier', NEW.created_by),
            (NEW.voucher_no, 'payment', NEW.payment_date, source_account_id, 0, NEW.amount, 'payment', NEW.id, 'Supplier payment made', NEW.created_by);
    END IF;
    
    RETURN NEW;
END;
$$;

-- Create the triggers
DROP TRIGGER IF EXISTS trigger_sale_ledger ON sales;
CREATE TRIGGER trigger_sale_ledger
    AFTER INSERT ON sales
    FOR EACH ROW
    EXECUTE FUNCTION create_sale_ledger_entries();

DROP TRIGGER IF EXISTS trigger_purchase_ledger ON purchases;
CREATE TRIGGER trigger_purchase_ledger
    AFTER INSERT ON purchases
    FOR EACH ROW
    EXECUTE FUNCTION create_purchase_ledger_entries();

DROP TRIGGER IF EXISTS trigger_receipt_ledger ON payments;
CREATE TRIGGER trigger_receipt_ledger
    AFTER INSERT ON payments
    FOR EACH ROW
    WHEN (NEW.payment_type = 'receipt')
    EXECUTE FUNCTION create_receipt_ledger_entries();

DROP TRIGGER IF EXISTS trigger_payment_ledger ON payments;
CREATE TRIGGER trigger_payment_ledger
    AFTER INSERT ON payments
    FOR EACH ROW
    WHEN (NEW.payment_type = 'payment')
    EXECUTE FUNCTION create_payment_ledger_entries();

-- Also ensure inventory triggers exist
DROP TRIGGER IF EXISTS trigger_purchase_inventory ON purchases;
CREATE TRIGGER trigger_purchase_inventory
    AFTER INSERT ON purchases
    FOR EACH ROW
    EXECUTE FUNCTION update_inventory_on_purchase();

DROP TRIGGER IF EXISTS trigger_sale_inventory ON sales;
CREATE TRIGGER trigger_sale_inventory
    AFTER INSERT ON sales
    FOR EACH ROW
    EXECUTE FUNCTION update_inventory_on_sale();
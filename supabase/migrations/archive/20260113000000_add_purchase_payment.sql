
-- Add columns to purchases table
ALTER TABLE public.purchases 
ADD COLUMN IF NOT EXISTS is_paid_now BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS payment_method TEXT CHECK (payment_method IN ('Cash', 'Bank Transfer', 'Cheque'));

-- Update the ledger entry trigger for purchases
CREATE OR REPLACE FUNCTION public.create_purchase_ledger_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    inventory_account_id UUID;
    payable_account_id UUID;
    cash_account_id UUID;
    bank_account_id UUID;
    credit_account_id UUID;
    narration_text TEXT;
BEGIN
    -- Get account IDs
    SELECT id INTO inventory_account_id FROM accounts WHERE code = '1200'; -- Fuel Inventory
    SELECT id INTO payable_account_id FROM accounts WHERE code = '2000'; -- Accounts Payable
    SELECT id INTO cash_account_id FROM accounts WHERE code = '1000'; -- Cash
    SELECT id INTO bank_account_id FROM accounts WHERE code = '1010'; -- Bank

    -- Determine Credit Account (Source of funds)
    IF NEW.is_paid_now THEN
        IF NEW.payment_method = 'Cash' THEN
            credit_account_id := cash_account_id;
            narration_text := 'Cash purchase from ' || (SELECT name FROM suppliers WHERE id = NEW.supplier_id);
        ELSE
            credit_account_id := bank_account_id;
            narration_text := 'Bank purchase from ' || (SELECT name FROM suppliers WHERE id = NEW.supplier_id);
        END IF;
    ELSE
        credit_account_id := payable_account_id;
        narration_text := 'Credit purchase from ' || (SELECT name FROM suppliers WHERE id = NEW.supplier_id);
    END IF;

    -- Debit Fuel Inventory (Asset Increase)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, inventory_account_id, NEW.total_amount, 0, 'purchase', NEW.id, narration_text, NEW.created_by);

    -- Credit Source Account (Asset Decrease or Liability Increase)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, credit_account_id, 0, NEW.total_amount, 'purchase', NEW.id, narration_text, NEW.created_by);
    
    RETURN NEW;
END;
$$;

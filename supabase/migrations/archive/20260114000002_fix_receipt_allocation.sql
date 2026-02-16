-- ========================================
-- CRITICAL FIX: Receipt Allocation Logic
-- Migration: 20260114000002_fix_receipt_allocation.sql
-- ========================================
-- PROBLEM: Receipts auto-allocate to AR vs Advances without explicit intent
-- SOLUTION: Add sale_id field + explicit allocation logic
-- ========================================

-- STEP 1: Add sale_id to payments table
-- ========================================
ALTER TABLE public.payments 
ADD COLUMN IF NOT EXISTS sale_id UUID REFERENCES public.sales(id);

COMMENT ON COLUMN public.payments.sale_id IS 
'Links receipt to specific sale/invoice. NULL = advance payment (no invoice)';

-- STEP 2: Create index for performance
CREATE INDEX IF NOT EXISTS idx_payments_sale_id ON public.payments(sale_id);

-- STEP 3: Replace Receipt Trigger with EXPLICIT Logic
-- ========================================

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
    sale_total NUMERIC;
    sale_ar_posted NUMERIC;
    sale_remaining_ar NUMERIC;
BEGIN
    -- Get account IDs
    SELECT id INTO cash_account_id FROM accounts WHERE code = '1000';
    SELECT id INTO bank_account_id FROM accounts WHERE code = '1010';
    SELECT id INTO receivable_account_id FROM accounts WHERE code = '1100';
    SELECT id INTO customer_advance_account_id FROM accounts WHERE code = '2100';
    
    -- Determine target cash account
    IF NEW.payment_method = 'Cash' THEN
        target_account_id := cash_account_id;
    ELSE
        target_account_id := bank_account_id;
    END IF;
    
    -- Only process receipts
    IF NEW.payment_type = 'receipt' THEN
        
        -- ========================================
        -- CRITICAL LOGIC: Explicit Allocation
        -- ========================================
        
        IF NEW.sale_id IS NOT NULL THEN
            -- ====================================
            -- SCENARIO 1: Receipt against specific sale/invoice
            -- ====================================
            
            -- Get sale details
            SELECT s.total_amount INTO sale_total
            FROM sales s
            WHERE s.id = NEW.sale_id AND s.is_credit = true;
            
            -- Validation: sale must exist and be credit sale
            IF sale_total IS NULL THEN
                RAISE EXCEPTION 'Invalid sale_id: % - Sale not found or not a credit sale', NEW.sale_id;
            END IF;
            
            -- Calculate how much AR was already posted for this sale
            SELECT COALESCE(SUM(debit_amount), 0) INTO sale_ar_posted
            FROM ledger_entries
            WHERE reference_type = 'sale'
              AND reference_id = NEW.sale_id
              AND account_id = receivable_account_id;
            
            -- Calculate how much AR was already settled via previous receipts
            sale_remaining_ar := sale_ar_posted - 
                COALESCE((SELECT SUM(credit_amount)
                         FROM ledger_entries le
                         JOIN payments p ON p.id = le.reference_id
                         WHERE p.sale_id = NEW.sale_id
                           AND le.account_id = receivable_account_id
                           AND p.payment_type = 'receipt'
                           AND p.id != NEW.id), 0);
            
            -- Validation: Receipt cannot exceed remaining AR for this invoice
            IF NEW.amount > sale_remaining_ar THEN
                RAISE EXCEPTION 'Receipt amount (%) exceeds remaining AR (%) for sale %', 
                    NEW.amount, sale_remaining_ar, NEW.sale_id;
            END IF;
            
            -- Post: Dr Cash, Cr Accounts Receivable (settle specific invoice)
            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
            VALUES 
                (NEW.voucher_no, 'receipt', NEW.payment_date, target_account_id, NEW.amount, 0, 'payment', NEW.id, 
                 'Receipt for Sale #' || (SELECT voucher_no FROM sales WHERE id = NEW.sale_id), NEW.created_by),
                (NEW.voucher_no, 'receipt', NEW.payment_date, receivable_account_id, 0, NEW.amount, 'payment', NEW.id, 
                 'AR settlement for Sale #' || (SELECT voucher_no FROM sales WHERE id = NEW.sale_id), NEW.created_by);
        
        ELSE
            -- ====================================
            -- SCENARIO 2: Advance payment (no invoice yet)
            -- ====================================
            
            -- Post: Dr Cash, Cr Customer Advances (liability - we owe them)
            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
            VALUES 
                (NEW.voucher_no, 'receipt', NEW.payment_date, target_account_id, NEW.amount, 0, 'payment', NEW.id, 
                 'Advance payment from customer (no invoice)', NEW.created_by),
                (NEW.voucher_no, 'receipt', NEW.payment_date, customer_advance_account_id, 0, NEW.amount, 'payment', NEW.id, 
                 'Customer advance received', NEW.created_by);
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

-- STEP 4: Update Payment Trigger (Simplified - same pattern)
-- ========================================
-- Add purchase_id for supplier payments

ALTER TABLE public.payments 
ADD COLUMN IF NOT EXISTS purchase_id UUID REFERENCES public.purchases(id);

COMMENT ON COLUMN public.payments.purchase_id IS 
'Links payment to specific purchase/invoice. NULL = advance payment';

CREATE INDEX IF NOT EXISTS idx_payments_purchase_id ON public.payments(purchase_id);

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
    purchase_total NUMERIC;
    purchase_ap_posted NUMERIC;
    purchase_remaining_ap NUMERIC;
BEGIN
    -- Get account IDs
    SELECT id INTO cash_account_id FROM accounts WHERE code = '1000';
    SELECT id INTO bank_account_id FROM accounts WHERE code = '1010';
    SELECT id INTO payable_account_id FROM accounts WHERE code = '2000';
    SELECT id INTO supplier_advance_account_id FROM accounts WHERE code = '1110';
    
    -- Determine source account
    IF NEW.payment_method = 'Cash' THEN
        source_account_id := cash_account_id;
    ELSE
        source_account_id := bank_account_id;
    END IF;
    
    -- Only process payments
    IF NEW.payment_type = 'payment' THEN
        
        IF NEW.purchase_id IS NOT NULL THEN
            -- Payment against specific purchase/invoice
            
            SELECT p.total_amount INTO purchase_total
            FROM purchases p
            WHERE p.id = NEW.purchase_id AND p.is_paid_now = false;
            
            IF purchase_total IS NULL THEN
                RAISE EXCEPTION 'Invalid purchase_id: % - Purchase not found or already paid', NEW.purchase_id;
            END IF;
            
            -- Calculate remaining AP for this purchase
            SELECT COALESCE(SUM(credit_amount), 0) INTO purchase_ap_posted
            FROM ledger_entries
            WHERE reference_type = 'purchase'
              AND reference_id = NEW.purchase_id
              AND account_id = payable_account_id;
            
            purchase_remaining_ap := purchase_ap_posted - 
                COALESCE((SELECT SUM(debit_amount)
                         FROM ledger_entries le
                         JOIN payments pm ON pm.id = le.reference_id
                         WHERE pm.purchase_id = NEW.purchase_id
                           AND le.account_id = payable_account_id
                           AND pm.payment_type = 'payment'
                           AND pm.id != NEW.id), 0);
            
            IF NEW.amount > purchase_remaining_ap THEN
                RAISE EXCEPTION 'Payment amount (%) exceeds remaining AP (%) for purchase %', 
                    NEW.amount, purchase_remaining_ap, NEW.purchase_id;
            END IF;
            
            -- Post: Dr Accounts Payable, Cr Cash
            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
            VALUES 
                (NEW.voucher_no, 'payment', NEW.payment_date, payable_account_id, NEW.amount, 0, 'payment', NEW.id, 
                 'Payment for Purchase #' || (SELECT voucher_no FROM purchases WHERE id = NEW.purchase_id), NEW.created_by),
                (NEW.voucher_no, 'payment', NEW.payment_date, source_account_id, 0, NEW.amount, 'payment', NEW.id, 
                 'AP settlement for Purchase #' || (SELECT voucher_no FROM purchases WHERE id = NEW.purchase_id), NEW.created_by);
        
        ELSE
            -- Advance payment (no invoice)
            
            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
            VALUES 
                (NEW.voucher_no, 'payment', NEW.payment_date, supplier_advance_account_id, NEW.amount, 0, 'payment', NEW.id, 
                 'Advance payment to supplier (no invoice)', NEW.created_by),
                (NEW.voucher_no, 'payment', NEW.payment_date, source_account_id, 0, NEW.amount, 'payment', NEW.id, 
                 'Supplier advance paid', NEW.created_by);
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

-- STEP 5: Re-register triggers
-- ========================================

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

-- ========================================
-- END OF MIGRATION
-- ========================================

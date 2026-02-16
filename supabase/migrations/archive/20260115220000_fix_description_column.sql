-- =================================================================
-- MIGRATION: 20260115220000_fix_description_column.sql
-- PURPOSE: Fix 'description' vs 'narration' mismatch
--          Standardize Supplier/Customer statement transactions
--          Ensure all purchases/sales appear in statements (Khata)
--          Fix Manage Transactions link to entities
-- VERIFIER: Antigravity
-- =================================================================

-- 1. Account Slug Standard (Reliable lookups)
DO $$
BEGIN
    UPDATE accounts SET slug = 'cash' WHERE code = '1000';
    UPDATE accounts SET slug = 'bank' WHERE code = '1010';
    UPDATE accounts SET slug = 'ar' WHERE code = '1100'; 
    UPDATE accounts SET slug = 'ap' WHERE code = '2000';
    UPDATE accounts SET slug = 'inventory' WHERE code = '1200';
    UPDATE accounts SET slug = 'sales' WHERE code = '4000';
    UPDATE accounts SET slug = 'cogs' WHERE code = '5000';
    UPDATE accounts SET slug = 'supplier_advance' WHERE code = '1110';
    UPDATE accounts SET slug = 'customer_advance' WHERE code = '2100';
END $$;

-- 2. Fixed Reporting RPCs (Showing EVERYTHING for a party)
-- =================================================================

-- A. Customer Statement
DROP FUNCTION IF EXISTS get_customer_ledger_statement(uuid);
CREATE OR REPLACE FUNCTION get_customer_ledger_statement(target_customer_id UUID)
RETURNS TABLE (
    entry_id UUID,
    posting_date DATE,
    voucher_no TEXT,
    voucher_type TEXT,
    narration TEXT,
    debit_amount NUMERIC,
    credit_amount NUMERIC,
    quantity NUMERIC,
    rate NUMERIC,
    fuel_type TEXT
) 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        le.id as entry_id,
        le.posting_date,
        le.voucher_no,
        le.voucher_type::text as voucher_type,
        le.narration,
        le.debit_amount,
        le.credit_amount,
        s.quantity,
        (s.total_amount / NULLIF(s.quantity, 0)) as rate,
        ft.name as fuel_type
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    LEFT JOIN sales s ON le.reference_type = 'sale' AND le.reference_id = s.id
    LEFT JOIN fuel_types ft ON s.fuel_type_id = ft.id
    LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
    WHERE 
        a.slug IN ('ar', 'customer_advance')
        AND (
            (s.customer_id = target_customer_id)
            OR (p.party_id = target_customer_id AND p.party_type = 'customer')
            OR (le.reference_id = target_customer_id AND le.reference_type IN ('money_movement', 'manage_transaction'))
        )
    ORDER BY le.posting_date ASC, le.created_at ASC;
END;
$$;

-- B. Supplier Statement
DROP FUNCTION IF EXISTS get_supplier_ledger_statement(uuid);
CREATE OR REPLACE FUNCTION get_supplier_ledger_statement(target_supplier_id UUID)
RETURNS TABLE (
    entry_id UUID,
    posting_date DATE,
    voucher_no TEXT,
    voucher_type TEXT,
    narration TEXT,
    debit_amount NUMERIC,
    credit_amount NUMERIC,
    quantity NUMERIC,
    rate NUMERIC,
    fuel_type TEXT
) 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        le.id as entry_id,
        le.posting_date,
        le.voucher_no,
        le.voucher_type::text as voucher_type,
        le.narration,
        le.debit_amount,
        le.credit_amount,
        pur.quantity,
        (pur.total_amount / NULLIF(pur.quantity, 0)) as rate,
        ft.name as fuel_type
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    LEFT JOIN purchases pur ON le.reference_type = 'purchase' AND le.reference_id = pur.id
    LEFT JOIN fuel_types ft ON pur.fuel_type_id = ft.id
    LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
    WHERE 
        a.slug IN ('ap', 'supplier_advance')
        AND (
            (pur.supplier_id = target_supplier_id)
            OR (p.party_id = target_supplier_id AND p.party_type = 'supplier')
            OR (le.reference_id = target_supplier_id AND le.reference_type IN ('money_movement', 'manage_transaction'))
        )
    ORDER BY le.posting_date ASC, le.created_at ASC;
END;
$$;

-- 3. Core Trigger Overhauls (Ensuring Khata Appearance)
-- =================================================================

-- A. SALE TRIGGER (Always through Customer AR)
CREATE OR REPLACE FUNCTION public.create_sale_ledger_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ar_id UUID; v_rev_id UUID; v_cash_id UUID;
    v_inv_id UUID; v_cogs_id UUID;
    v_cogs_amount NUMERIC; v_avg_cost NUMERIC;
    v_user_id UUID;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN SELECT id INTO v_user_id FROM auth.users LIMIT 1; END IF;

    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_rev_id FROM accounts WHERE slug = 'sales';
    SELECT id INTO v_cash_id FROM accounts WHERE slug = 'cash';
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM accounts WHERE slug = 'cogs';

    -- COGS Calculation
    SELECT avg_cost INTO v_avg_cost FROM inventory WHERE fuel_type_id = NEW.fuel_type_id;
    v_cogs_amount := NEW.quantity * COALESCE(v_avg_cost, 0);

    -- STEP 1: Always record Sale against AR
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.total_amount, 0, 'sale', NEW.id, 'Sale Invoice', v_user_id),
           (NEW.voucher_no, 'sale', NEW.sale_date, v_rev_id, 0, NEW.total_amount, 'sale', NEW.id, 'Revenue', v_user_id);

    -- STEP 2: If Cash, record immediate receipt from AR
    IF NOT NEW.is_credit THEN
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
        VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_cash_id, NEW.total_amount, 0, 'sale', NEW.id, 'Cash Sale Payment', v_user_id),
               (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, 0, NEW.total_amount, 'sale', NEW.id, 'AR Clearing', v_user_id);
    ELSE
        -- Update balance column for credit sales
        UPDATE customers SET current_balance = current_balance + NEW.total_amount WHERE id = NEW.customer_id;
    END IF;

    -- STEP 3: Inventory
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, v_cogs_amount, 0, 'sale', NEW.id, 'COGS', v_user_id),
           (NEW.voucher_no, 'sale', NEW.sale_date, v_inv_id, 0, v_cogs_amount, 'sale', NEW.id, 'Inventory Out', v_user_id);

    RETURN NEW;
END;
$$;

-- B. PURCHASE TRIGGER (Always through Supplier AP)
CREATE OR REPLACE FUNCTION public.create_purchase_ledger_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ap_id UUID; v_inv_id UUID; v_cash_id UUID; v_bank_id UUID;
    v_src_id UUID; v_user_id UUID;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN SELECT id INTO v_user_id FROM auth.users LIMIT 1; END IF;

    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_cash_id FROM accounts WHERE slug = 'cash';
    SELECT id INTO v_bank_id FROM accounts WHERE slug = 'bank';
    v_src_id := CASE WHEN NEW.payment_method = 'Cash' THEN v_cash_id ELSE v_bank_id END;

    -- STEP 1: Always record Purchase against AP
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv_id, NEW.total_amount, 0, 'purchase', NEW.id, 'Inventory Purchase', v_user_id),
           (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, 0, NEW.total_amount, 'purchase', NEW.id, 'Supplier Credit', v_user_id);

    -- STEP 2: If Paid Now, record immediate payment from AP
    IF NEW.is_paid_now THEN
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
        VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.total_amount, 0, 'purchase', NEW.id, 'Purchase Payment', v_user_id),
               (NEW.voucher_no, 'purchase', NEW.purchase_date, v_src_id, 0, NEW.total_amount, 'purchase', NEW.id, 'Payment Out', v_user_id);
    ELSE
        -- Update balance column for credit purchases
        UPDATE suppliers SET current_balance = current_balance + NEW.total_amount WHERE id = NEW.supplier_id;
    END IF;

    RETURN NEW;
END;
$$;

-- C. Unified Manage Transaction Function (Fixing Entity Tracking)
CREATE OR REPLACE FUNCTION create_manage_transaction(
    p_transaction_type TEXT,    -- 'sale', 'purchase', 'receipt', 'payment'
    p_from_type TEXT,           -- 'cash', 'bank', 'entity'
    p_from_entity_id UUID,      
    p_to_type TEXT,             
    p_to_entity_id UUID,        
    p_amount NUMERIC,
    p_narration TEXT,
    p_transaction_date DATE
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_voucher_no TEXT; v_dr_id UUID; v_cr_id UUID; v_entity_id UUID;
    v_cash_id UUID; v_bank_id UUID; v_ar_id UUID; v_ap_id UUID; v_rev_id UUID; v_inv_id UUID;
BEGIN
    SELECT id INTO v_cash_id FROM accounts WHERE slug = 'cash';
    SELECT id INTO v_bank_id FROM accounts WHERE slug = 'bank';
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';
    SELECT id INTO v_rev_id FROM accounts WHERE slug = 'sales';
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';

    v_voucher_no := 'MT-' || TO_CHAR(p_transaction_date, 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');

    IF p_transaction_type = 'receipt' THEN
        v_dr_id := CASE WHEN p_to_type = 'cash' THEN v_cash_id ELSE v_bank_id END;
        v_cr_id := v_ar_id;
        v_entity_id := p_from_entity_id;
        UPDATE customers SET current_balance = current_balance - p_amount WHERE id = v_entity_id;
    ELSIF p_transaction_type = 'payment' THEN
        v_dr_id := v_ap_id;
        v_cr_id := CASE WHEN p_from_type = 'cash' THEN v_cash_id ELSE v_bank_id END;
        v_entity_id := p_to_entity_id;
        UPDATE suppliers SET current_balance = current_balance - p_amount WHERE id = v_entity_id;
    ELSIF p_transaction_type = 'sale' THEN
        v_dr_id := v_ar_id; v_cr_id := v_rev_id; v_entity_id := p_to_entity_id;
        UPDATE customers SET current_balance = current_balance + p_amount WHERE id = v_entity_id;
    ELSIF p_transaction_type = 'purchase' THEN
        v_dr_id := v_inv_id; v_cr_id := v_ap_id; v_entity_id := p_from_entity_id;
        UPDATE suppliers SET current_balance = current_balance + p_amount WHERE id = v_entity_id;
    ELSE
        RAISE EXCEPTION 'Invalid transaction type';
    END IF;

    INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, reference_id, created_by)
    VALUES (v_dr_id, p_transaction_date, p_amount, 0, p_narration, v_voucher_no, 'manage_transaction', 'manage_transaction', v_entity_id, auth.uid()),
           (v_cr_id, p_transaction_date, 0, p_amount, p_narration, v_voucher_no, 'manage_transaction', 'manage_transaction', v_entity_id, auth.uid());

    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END;
$$;

-- D. Munshi Khata View Fix
DROP VIEW IF EXISTS view_munshi_khata CASCADE;
CREATE OR REPLACE VIEW view_munshi_khata AS
SELECT 
    le.posting_date as "Tareekh",
    le.voucher_no as "Raseed_No",
    le.narration as "Tafseel",
    CASE WHEN le.debit_amount > 0 THEN le.debit_amount ELSE 0 END as "Naam (Dr)",
    CASE WHEN le.credit_amount > 0 THEN le.credit_amount ELSE 0 END as "Jama (Cr)",
    a.name as "Khata",
    le.created_at
FROM ledger_entries le
JOIN accounts a ON le.account_id = a.id
ORDER BY le.posting_date DESC, le.created_at DESC;

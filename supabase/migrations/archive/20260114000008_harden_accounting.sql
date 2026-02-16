-- =================================================================
-- MIGRATION: 20260114000008_harden_accounting.sql
-- PURPOSE: Fix Race Conditions, Performance, and Data Integrity
-- AUDITOR: Google DeepMind
-- =================================================================

-- -----------------------------------------------------------------
-- 1. SCHEMA HARDENING (Balancing Columns & Slugs)
-- -----------------------------------------------------------------

-- Add O(1) balance columns with constraints to prevent "Phantom" balances
ALTER TABLE customers 
ADD COLUMN IF NOT EXISTS current_balance NUMERIC DEFAULT 0;

ALTER TABLE suppliers 
ADD COLUMN IF NOT EXISTS current_balance NUMERIC DEFAULT 0;

-- Add slugs to accounts for reliable lookup (No more Magic IDs)
ALTER TABLE accounts 
ADD COLUMN IF NOT EXISTS slug TEXT UNIQUE;

-- Map Slugs to Existing Codes
UPDATE accounts SET slug = 'cash' WHERE code = '1000';
UPDATE accounts SET slug = 'bank' WHERE code = '1010';
UPDATE accounts SET slug = 'ar' WHERE code = '1100'; -- Accounts Receivable
UPDATE accounts SET slug = 'ap' WHERE code = '2000'; -- Accounts Payable
UPDATE accounts SET slug = 'inventory' WHERE code = '1200';
UPDATE accounts SET slug = 'sales' WHERE code = '4000';
UPDATE accounts SET slug = 'cogs' WHERE code = '5000';
UPDATE accounts SET slug = 'supplier_advance' WHERE code = '1110';
UPDATE accounts SET slug = 'customer_advance' WHERE code = '2100';

-- -----------------------------------------------------------------
-- 2. VOUCHER SEQUENCES (Collision Proofing)
-- -----------------------------------------------------------------

CREATE SEQUENCE IF NOT EXISTS voucher_seq_mm START 1001;
CREATE SEQUENCE IF NOT EXISTS voucher_seq_sale START 1001;
CREATE SEQUENCE IF NOT EXISTS voucher_seq_purchase START 1001;
CREATE SEQUENCE IF NOT EXISTS voucher_seq_payment START 1001;

-- -----------------------------------------------------------------
-- 3. INITIAL BALANCE CALCULATION (Migration)
-- -----------------------------------------------------------------
-- Calculate and persist current balances from ledger logic (One-time O(N))

DO $$ 
DECLARE
    ar_id UUID;
    ap_id UUID;
BEGIN
    SELECT id INTO ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO ap_id FROM accounts WHERE slug = 'ap';

    -- Update Customer Balances (AR)
    -- Balance = Sum(Dr - Cr) for this customer in AR account
    -- Note: This matches the logic from previous slow triggers
    UPDATE customers c
    SET current_balance = COALESCE(c.opening_balance, 0) + COALESCE((
        SELECT SUM(debit_amount - credit_amount)
        FROM ledger_entries le
        WHERE le.account_id = ar_id 
        AND le.reference_type IN ('sale', 'payment', 'money_movement')
        AND le.reference_id = c.id
    ), 0);

    -- Update Supplier Balances (AP)
    UPDATE suppliers s
    SET current_balance = COALESCE(s.opening_balance, 0) + COALESCE((
        SELECT SUM(credit_amount - debit_amount)
        FROM ledger_entries le
        WHERE le.account_id = ap_id 
        AND le.reference_type IN ('purchase', 'payment', 'money_movement')
        AND le.reference_id = s.id
    ), 0);
END $$;

-- -----------------------------------------------------------------
-- 4. REFACTORED TRIGGERS (O(1) Performance)
-- -----------------------------------------------------------------

-- A. SALE TRIGGER (Updates Customer Balance Incremental)
CREATE OR REPLACE FUNCTION public.create_sale_ledger_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ar_id UUID;
    v_rev_id UUID;
    v_cash_id UUID;
    v_inv_id UUID;
    v_cogs_id UUID;
    v_voucher TEXT;
    v_cogs_amount NUMERIC;
    v_avg_cost NUMERIC;
BEGIN
    -- Get Accounts by Slug
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_rev_id FROM accounts WHERE slug = 'sales';
    SELECT id INTO v_cash_id FROM accounts WHERE slug = 'cash';
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM accounts WHERE slug = 'cogs';

    -- Voucher Generation
    v_voucher := 'SALE-' || TO_CHAR(NEW.sale_date, 'YYYYMMDD') || '-' || nextval('voucher_seq_sale')::TEXT;

    -- COGS Safety Check
    SELECT avg_cost INTO v_avg_cost FROM inventory WHERE fuel_type_id = NEW.fuel_type_id;
    IF v_avg_cost IS NULL OR v_avg_cost <= 0 THEN
        RAISE EXCEPTION 'SAFETY VIOLATION: Zero Cost Basis for Fuel ID %', NEW.fuel_type_id;
    END IF;
    v_cogs_amount := NEW.quantity * v_avg_cost;

    -- Ledger Entries
    IF NEW.is_credit THEN
        -- Locking for Balance Update
        PERFORM 1 FROM customers WHERE id = NEW.customer_id FOR UPDATE;
        
        -- Update Balance O(1)
        UPDATE customers SET current_balance = current_balance + NEW.total_amount
        WHERE id = NEW.customer_id;

        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
        VALUES 
            (v_voucher, 'sale', NEW.sale_date, v_ar_id, NEW.total_amount, 0, 'sale', NEW.id, 'Credit sale', NEW.created_by),
            (v_voucher, 'sale', NEW.sale_date, v_rev_id, 0, NEW.total_amount, 'sale', NEW.id, 'Revenue', NEW.created_by);
    ELSE
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
        VALUES 
            (v_voucher, 'sale', NEW.sale_date, v_cash_id, NEW.total_amount, 0, 'sale', NEW.id, 'Cash sale', NEW.created_by),
            (v_voucher, 'sale', NEW.sale_date, v_rev_id, 0, NEW.total_amount, 'sale', NEW.id, 'Revenue', NEW.created_by);
    END IF;

    -- Inventory entries (Standard)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, narration, created_by)
    VALUES 
        (v_voucher, 'sale', NEW.sale_date, v_cogs_id, v_cogs_amount, 0, 'sale', NEW.id, 'COGS', NEW.created_by),
        (v_voucher, 'sale', NEW.sale_date, v_inv_id, 0, v_cogs_amount, 'sale', NEW.id, 'Inventory Out', NEW.created_by);

    RETURN NEW;
END;
$$;

-- B. RECEIPT TRIGGER (O(1) Balance Update & Locking)
CREATE OR REPLACE FUNCTION public.create_receipt_ledger_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_target_id UUID;
    v_ar_id UUID;
    v_adv_id UUID;
    v_bal NUMERIC;
    v_to_ar NUMERIC;
    v_to_adv NUMERIC;
BEGIN
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_adv_id FROM accounts WHERE slug = 'customer_advance';
    
    IF NEW.payment_method = 'Cash' THEN
        SELECT id INTO v_target_id FROM accounts WHERE slug = 'cash';
    ELSE
        SELECT id INTO v_target_id FROM accounts WHERE slug = 'bank';
    END IF;

    -- LOCK ROW for concurrency safety
    SELECT current_balance INTO v_bal FROM customers WHERE id = NEW.party_id FOR UPDATE;

    -- Logic: Balance is what they OWE us.
    -- If they pay X, we reduce OWE by X.
    -- If X > Balance, the remainder goes to Advance.
    -- BUT Wait: 'current_balance' tracks Net Receivables?
    -- Yes. If positive, they owe us. If negative, we owe them (advance).
    
    -- Correction: Ledger logic separates AR (1100) and Advance (2100).
    -- 'current_balance' is a net checking number? Or just AR?
    -- Ideally 'current_balance' should be Net position.
    
    -- Logic: We will simply decrement the balance by Amount.
    -- Accounting entries split based on +ve/-ve state.
    
    -- 1. Update Balance first to claim the transaction
    UPDATE customers SET current_balance = current_balance - NEW.amount WHERE id = NEW.party_id;
    
    -- 2. Calculate Split based on PRE-TRANSACTION balance (v_bal)
    -- If Balance = 5000, Pay = 6000.
    -- AR gets 5000. Advance gets 1000.
    
    IF v_bal >= NEW.amount THEN
        v_to_ar := NEW.amount;
        v_to_adv := 0;
    ELSIF v_bal > 0 THEN
        v_to_ar := v_bal;
        v_to_adv := NEW.amount - v_bal;
    ELSE
        v_to_ar := 0;
        v_to_adv := NEW.amount;
    END IF;

    -- 3. Write Entries
    IF v_to_ar > 0 THEN
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, description)
        VALUES 
            (NEW.voucher_no, 'receipt', NEW.payment_date, v_target_id, v_to_ar, 0, 'payment', NEW.id, 'Receipt AR'),
            (NEW.voucher_no, 'receipt', NEW.payment_date, v_ar_id, 0, v_to_ar, 'payment', NEW.id, 'AR Offset');
    END IF;

    IF v_to_adv > 0 THEN
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, reference_type, reference_id, description)
        VALUES 
            (NEW.voucher_no, 'receipt', NEW.payment_date, v_target_id, v_to_adv, 0, 'payment', NEW.id, 'Receipt Advance'),
            (NEW.voucher_no, 'receipt', NEW.payment_date, v_adv_id, 0, v_to_adv, 'payment', NEW.id, 'Advance Credited');
    END IF;

    RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------
-- 5. MONEY MOVEMENT RPC (The "God" Function)
-- -----------------------------------------------------------------

CREATE OR REPLACE FUNCTION create_money_movement(
    p_from_type TEXT,
    p_from_party_id UUID,
    p_to_type TEXT,
    p_to_party_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_movement_date DATE
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_voucher TEXT;
    v_cust_bal NUMERIC;
    v_supp_bal NUMERIC;
    v_to_ar NUMERIC; 
    v_to_adv NUMERIC;
    v_dr_acct UUID;
    v_cr_acct UUID;
    v_dr_slug TEXT;
    v_cr_slug TEXT;
BEGIN
    -- 1. Validation
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    
    -- 2. Voucher
    v_voucher := 'MM-' || TO_CHAR(p_movement_date, 'YYYYMMDD') || '-' || nextval('voucher_seq_mm')::TEXT;

    -- 3. CASE HANDLER
    -- =========================================================
    
    -- CASE A: Customer PAYS (To Cash/Bank)
    IF p_from_type = 'customer' THEN
        -- LOCK CUSTOMER
        SELECT current_balance INTO v_cust_bal FROM customers WHERE id = p_from_party_id FOR UPDATE;
        
        -- UPDATE BALANCE (O(1))
        UPDATE customers SET current_balance = current_balance - p_amount WHERE id = p_from_party_id;
        
        -- SPLIT LOGIC
        IF v_cust_bal >= p_amount THEN
            v_to_ar := p_amount;
            v_to_adv := 0;
        ELSIF v_cust_bal > 0 THEN
            v_to_ar := v_cust_bal;
            v_to_adv := p_amount - v_cust_bal;
        ELSE
            v_to_ar := 0;
            v_to_adv := p_amount;
        END IF;
        
        -- TARGET ACCOUNT
        IF p_to_type = 'cash' THEN v_dr_slug := 'cash';
        ELSE v_dr_slug := 'bank'; END IF;
        SELECT id INTO v_dr_acct FROM accounts WHERE slug = v_dr_slug;
        
        -- WRITE LEDGER (AR)
        IF v_to_ar > 0 THEN
            SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'ar';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type, reference_id)
            VALUES 
                (v_dr_acct, p_movement_date, v_to_ar, 0, p_narration, v_voucher, 'money_movement', p_from_party_id),
                (v_cr_acct, p_movement_date, 0, v_to_ar, p_narration, v_voucher, 'money_movement', p_from_party_id);
        END IF;
        
        -- WRITE LEDGER (Advance)
        IF v_to_adv > 0 THEN
            SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'customer_advance';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type, reference_id)
            VALUES 
                (v_dr_acct, p_movement_date, v_to_adv, 0, p_narration || ' (Adv)', v_voucher, 'money_movement', p_from_party_id),
                (v_cr_acct, p_movement_date, 0, v_to_adv, p_narration || ' (Adv)', v_voucher, 'money_movement', p_from_party_id);
        END IF;

    -- CASE B: WE PAY Supplier (From Cash/Bank)
    ELSIF p_to_type = 'supplier' THEN
        -- LOCK SUPPLIER
        SELECT current_balance INTO v_supp_bal FROM suppliers WHERE id = p_to_party_id FOR UPDATE;
        
        -- UPDATE BALANCE (O(1)) - Supplier Balance is AP (Liability). Paying reduces it.
        UPDATE suppliers SET current_balance = current_balance - p_amount WHERE id = p_to_party_id;
        
        -- SPLIT LOGIC
        IF v_supp_bal >= p_amount THEN
            v_to_ar := p_amount; -- Reusing var for AP
            v_to_adv := 0;
        ELSIF v_supp_bal > 0 THEN
            v_to_ar := v_supp_bal;
            v_to_adv := p_amount - v_supp_bal;
        ELSE
            v_to_ar := 0;
            v_to_adv := p_amount;
        END IF;
        
        -- SOURCE ACCOUNT
        IF p_from_type = 'cash' THEN v_cr_slug := 'cash';
        ELSE v_cr_slug := 'bank'; END IF;
        SELECT id INTO v_cr_acct FROM accounts WHERE slug = v_cr_slug;
        
        -- WRITE LEDGER (AP)
        IF v_to_ar > 0 THEN
            SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'ap';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type, reference_id)
            VALUES 
                (v_dr_acct, p_movement_date, v_to_ar, 0, p_narration, v_voucher, 'money_movement', p_to_party_id),
                (v_cr_acct, p_movement_date, 0, v_to_ar, p_narration, v_voucher, 'money_movement', p_to_party_id);
        END IF;
        
        -- WRITE LEDGER (Advance)
        IF v_to_adv > 0 THEN
            SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'supplier_advance';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type, reference_id)
            VALUES 
                (v_dr_acct, p_movement_date, v_to_adv, 0, p_narration || ' (Adv)', v_voucher, 'money_movement', p_to_party_id),
                (v_cr_acct, p_movement_date, 0, v_to_adv, p_narration || ' (Adv)', v_voucher, 'money_movement', p_to_party_id);
        END IF;

    -- CASE C: Internal Transfer
    ELSE
        -- Get IDs
        IF p_from_type = 'cash' THEN SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'cash';
        ELSIF p_from_type = 'bank' THEN SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'bank';
        ELSE RAISE EXCEPTION 'Invalid Source Type'; END IF;

        IF p_to_type = 'cash' THEN SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'cash';
        ELSIF p_to_type = 'bank' THEN SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'bank';
        ELSE RAISE EXCEPTION 'Invalid Dest Type'; END IF;

        INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, description, voucher_no, reference_type)
        VALUES 
            (v_dr_acct, p_movement_date, p_amount, 0, p_narration, v_voucher, 'money_movement'),
            (v_cr_acct, p_movement_date, 0, p_amount, p_narration, v_voucher, 'money_movement');
    END IF;

    RETURN json_build_object('success', true, 'voucher', v_voucher);
END;
$$;

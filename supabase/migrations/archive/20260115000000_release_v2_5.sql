-- =================================================================
-- RELEASE: v2.5 CONSOLIDATED PATCH (The "All-in-One" Fix)
-- DATE: 2026-01-15
-- PURPOSE: Applies Schema Hardening, Merkle Security, and RPC Fixes
--          Replaces migrations 08 through 16 with a single safe run.
-- =================================================================

-- -----------------------------------------------------------------
-- 1. SCHEMA HARDENING (Safe to run multiple times)
-- -----------------------------------------------------------------

-- Balances & Slugs
ALTER TABLE customers ADD COLUMN IF NOT EXISTS current_balance NUMERIC DEFAULT 0;
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS current_balance NUMERIC DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS slug TEXT UNIQUE;
ALTER TABLE ledger_entries ADD COLUMN IF NOT EXISTS idempotency_key UUID UNIQUE;

-- Map Slugs
UPDATE accounts SET slug = 'cash' WHERE code = '1000';
UPDATE accounts SET slug = 'bank' WHERE code = '1010';
UPDATE accounts SET slug = 'ar' WHERE code = '1100'; 
UPDATE accounts SET slug = 'ap' WHERE code = '2000';
UPDATE accounts SET slug = 'inventory' WHERE code = '1200';
UPDATE accounts SET slug = 'sales' WHERE code = '4000';
UPDATE accounts SET slug = 'cogs' WHERE code = '5000';
UPDATE accounts SET slug = 'supplier_advance' WHERE code = '1110';
UPDATE accounts SET slug = 'customer_advance' WHERE code = '2100';

-- Sequences
CREATE SEQUENCE IF NOT EXISTS voucher_seq_mm START 1001;
CREATE SEQUENCE IF NOT EXISTS voucher_seq_sale START 1001;
CREATE SEQUENCE IF NOT EXISTS voucher_seq_purchase START 1001;
CREATE SEQUENCE IF NOT EXISTS voucher_seq_payment START 1001;

-- Voucher Type Enum Update
DO $$
BEGIN
    ALTER TYPE voucher_type ADD VALUE IF NOT EXISTS 'money_movement';
EXCEPTION
    WHEN duplicate_object THEN null; 
    WHEN OTHERS THEN RAISE NOTICE 'Enum update skipped/failed';
END $$;

-- Integrity Tables
CREATE TABLE IF NOT EXISTS ledger_integrity_hashes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_date DATE NOT NULL UNIQUE,
    entry_count INTEGER NOT NULL,
    ledger_hash TEXT NOT NULL,
    prev_hash TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    verified_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS accounting_periods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    is_closed BOOLEAN DEFAULT false,
    closed_at TIMESTAMPTZ,
    closed_by UUID
);

-- Inventory Constraint (Fail Loud)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'inventory') THEN
        ALTER TABLE inventory DROP CONSTRAINT IF EXISTS no_negative_inventory;
        ALTER TABLE inventory ADD CONSTRAINT no_negative_inventory CHECK (quantity >= 0);
    END IF;
END $$;

-- -----------------------------------------------------------------
-- 2. CORE FUNCTIONS (Latest Versions as of Test 16)
-- -----------------------------------------------------------------

-- A. MERKLE HASH (Chained)
CREATE OR REPLACE FUNCTION generate_daily_ledger_hash(p_date DATE)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_content TEXT;
    v_prev_hash TEXT;
    v_final_hash TEXT;
    v_count INTEGER;
BEGIN
    SELECT STRING_AGG(
        id::text || voucher_no || account_id::text || debit_amount::text || credit_amount::text || created_at::text,
        '|' ORDER BY created_at, id
    ), COUNT(*)
    INTO v_content, v_count
    FROM ledger_entries
    WHERE posting_date = p_date;
    
    IF v_content IS NULL THEN v_content := 'EMPTY_DAY'; v_count := 0; END IF;
    
    SELECT ledger_hash INTO v_prev_hash FROM ledger_integrity_hashes 
    WHERE period_date < p_date ORDER BY period_date DESC LIMIT 1;
    
    IF v_prev_hash IS NULL THEN v_prev_hash := 'GENESIS_HASH_START_0000'; END IF;
    
    v_final_hash := md5(v_prev_hash || '||' || v_content);
    
    INSERT INTO ledger_integrity_hashes (period_date, entry_count, ledger_hash, prev_hash, verified_at)
    VALUES (p_date, v_count, v_final_hash, v_prev_hash, NOW())
    ON CONFLICT (period_date) DO UPDATE 
    SET ledger_hash = EXCLUDED.ledger_hash, prev_hash = EXCLUDED.prev_hash, entry_count = EXCLUDED.entry_count, verified_at = NOW();
        
    RETURN v_final_hash;
END;
$$;

-- B. AUDIT BALANCE (Net Position)
CREATE OR REPLACE FUNCTION audit_verify_customer_balance(p_customer_id UUID)
RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
    v_stored_bal NUMERIC;
    v_calc_bal NUMERIC;
    v_ar_id UUID;
    v_adv_id UUID;
BEGIN
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_adv_id FROM accounts WHERE slug = 'customer_advance';
    SELECT current_balance INTO v_stored_bal FROM customers WHERE id = p_customer_id;
    
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0) + 
           (SELECT COALESCE(opening_balance, 0) FROM customers WHERE id = p_customer_id)
    INTO v_calc_bal
    FROM ledger_entries
    WHERE account_id IN (v_ar_id, v_adv_id) 
    AND reference_type IN ('sale', 'payment', 'money_movement')
    AND reference_id = p_customer_id;
    
    IF v_stored_bal != v_calc_bal THEN
        RAISE EXCEPTION 'CRITICAL INTEGRITY FAILURE: Customer % Stored Balance (%) != Ledger Balance (%)', p_customer_id, v_stored_bal, v_calc_bal;
    END IF;
    RETURN json_build_object('status', 'OK', 'balance', v_stored_bal);
END;
$$;

-- C. MONEY MOVEMENT (The main engine)
DROP FUNCTION IF EXISTS create_money_movement(text, uuid, text, uuid, numeric, text, date);
DROP FUNCTION IF EXISTS create_money_movement(text, text, text, text, numeric, text, date);

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
    v_user_id UUID;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN SELECT id INTO v_user_id FROM auth.users LIMIT 1; END IF;
    IF v_user_id IS NULL THEN RAISE CHECK_VIOLATION USING MESSAGE = 'No authenticated user found.'; END IF;

    v_voucher := 'MM-' || TO_CHAR(p_movement_date, 'YYYYMMDD') || '-' || nextval('voucher_seq_mm')::TEXT;

    IF p_from_type = 'customer' THEN
        SELECT current_balance INTO v_cust_bal FROM customers WHERE id = p_from_party_id FOR UPDATE;
        UPDATE customers SET current_balance = current_balance - p_amount WHERE id = p_from_party_id;
        IF v_cust_bal >= p_amount THEN v_to_ar := p_amount; v_to_adv := 0;
        ELSIF v_cust_bal > 0 THEN v_to_ar := v_cust_bal; v_to_adv := p_amount - v_cust_bal;
        ELSE v_to_ar := 0; v_to_adv := p_amount; END IF;
        
        IF p_to_type = 'cash' THEN v_dr_slug := 'cash'; ELSE v_dr_slug := 'bank'; END IF;
        SELECT id INTO v_dr_acct FROM accounts WHERE slug = v_dr_slug;
        
        IF v_to_ar > 0 THEN
            SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'ar';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, reference_id, created_by)
            VALUES (v_dr_acct, p_movement_date, v_to_ar, 0, p_narration, v_voucher, 'money_movement'::voucher_type, 'money_movement', p_from_party_id, v_user_id),
                   (v_cr_acct, p_movement_date, 0, v_to_ar, p_narration, v_voucher, 'money_movement'::voucher_type, 'money_movement', p_from_party_id, v_user_id);
        END IF; 
        IF v_to_adv > 0 THEN
            SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'customer_advance';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, reference_id, created_by)
            VALUES (v_dr_acct, p_movement_date, v_to_adv, 0, p_narration || ' (Adv)', v_voucher, 'money_movement'::voucher_type, 'money_movement', p_from_party_id, v_user_id),
                   (v_cr_acct, p_movement_date, 0, v_to_adv, p_narration || ' (Adv)', v_voucher, 'money_movement'::voucher_type, 'money_movement', p_from_party_id, v_user_id);
        END IF;

    ELSIF p_to_type = 'supplier' THEN
        SELECT current_balance INTO v_supp_bal FROM suppliers WHERE id = p_to_party_id FOR UPDATE;
        UPDATE suppliers SET current_balance = current_balance - p_amount WHERE id = p_to_party_id;
        IF v_supp_bal >= p_amount THEN v_to_ar := p_amount; v_to_adv := 0;
        ELSIF v_supp_bal > 0 THEN v_to_ar := v_supp_bal; v_to_adv := p_amount - v_supp_bal;
        ELSE v_to_ar := 0; v_to_adv := p_amount; END IF;
        
        IF p_from_type = 'cash' THEN v_cr_slug := 'cash'; ELSE v_cr_slug := 'bank'; END IF;
        SELECT id INTO v_cr_acct FROM accounts WHERE slug = v_cr_slug;
        
        IF v_to_ar > 0 THEN
            SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'ap';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, reference_id, created_by)
            VALUES (v_dr_acct, p_movement_date, v_to_ar, 0, p_narration, v_voucher, 'money_movement'::voucher_type, 'money_movement', p_to_party_id, v_user_id),
                   (v_cr_acct, p_movement_date, 0, v_to_ar, p_narration, v_voucher, 'money_movement'::voucher_type, 'money_movement', p_to_party_id, v_user_id);
        END IF; 
        IF v_to_adv > 0 THEN
            SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'supplier_advance';
            INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, reference_id, created_by)
            VALUES (v_dr_acct, p_movement_date, v_to_adv, 0, p_narration || ' (Adv)', v_voucher, 'money_movement'::voucher_type, 'money_movement', p_to_party_id, v_user_id),
                   (v_cr_acct, p_movement_date, 0, v_to_adv, p_narration || ' (Adv)', v_voucher, 'money_movement'::voucher_type, 'money_movement', p_to_party_id, v_user_id);
        END IF;

    ELSE
        IF p_from_type = 'cash' THEN SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'cash';
        ELSIF p_from_type = 'bank' THEN SELECT id INTO v_cr_acct FROM accounts WHERE slug = 'bank'; END IF;
        IF p_to_type = 'cash' THEN SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'cash';
        ELSIF p_to_type = 'bank' THEN SELECT id INTO v_dr_acct FROM accounts WHERE slug = 'bank'; END IF;

        INSERT INTO ledger_entries (account_id, posting_date, debit_amount, credit_amount, narration, voucher_no, voucher_type, reference_type, created_by)
        VALUES (v_dr_acct, p_movement_date, p_amount, 0, p_narration, v_voucher, 'money_movement'::voucher_type, 'money_movement', v_user_id),
               (v_cr_acct, p_movement_date, 0, p_amount, p_narration, v_voucher, 'money_movement'::voucher_type, 'money_movement', v_user_id);
    END IF;
    RETURN json_build_object('success', true, 'voucher', v_voucher);
END;
$$;

-- D. REPORTING RPCS

-- 1. Top Customers
DROP FUNCTION IF EXISTS get_top_customers_balances(integer);
DROP FUNCTION IF EXISTS get_top_customers_balances();
CREATE OR REPLACE FUNCTION get_top_customers_balances(limit_count INTEGER DEFAULT 5)
RETURNS TABLE (id UUID, name TEXT, balance NUMERIC) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY SELECT c.id, c.name, c.current_balance FROM customers c WHERE c.current_balance != 0 ORDER BY c.current_balance DESC LIMIT limit_count;
END; $$;

-- 2. Daily Summary
DROP FUNCTION IF EXISTS get_daily_summary(date);
DROP FUNCTION IF EXISTS get_daily_summary();
CREATE OR REPLACE FUNCTION get_daily_summary(target_date DATE DEFAULT CURRENT_DATE)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_total_sales NUMERIC; v_total_purchases NUMERIC; v_cash_in NUMERIC; v_cash_out NUMERIC;
    v_sales_id UUID; v_cash_id UUID; v_bank_id UUID;
BEGIN
    SELECT id INTO v_sales_id FROM accounts WHERE slug = 'sales';
    SELECT id INTO v_cash_id FROM accounts WHERE slug = 'cash';
    SELECT id INTO v_bank_id FROM accounts WHERE slug = 'bank';
    SELECT COALESCE(SUM(credit_amount), 0) INTO v_total_sales FROM ledger_entries WHERE account_id = v_sales_id AND posting_date = target_date;
    SELECT COALESCE(SUM(total_amount), 0) INTO v_total_purchases FROM purchases WHERE purchase_date = target_date;
    SELECT COALESCE(SUM(debit_amount), 0) INTO v_cash_in FROM ledger_entries WHERE account_id IN (v_cash_id, v_bank_id) AND posting_date = target_date;
    SELECT COALESCE(SUM(credit_amount), 0) INTO v_cash_out FROM ledger_entries WHERE account_id IN (v_cash_id, v_bank_id) AND posting_date = target_date;
    RETURN json_build_object('total_sales', v_total_sales, 'total_purchases', v_total_purchases, 'cash_in', v_cash_in, 'cash_out', v_cash_out);
END; $$;

-- 3. Trial Balance (The 400 Error Fix)
DROP FUNCTION IF EXISTS get_trial_balance(date, date);
DROP FUNCTION IF EXISTS get_trial_balance();
CREATE OR REPLACE FUNCTION get_trial_balance(
    start_date DATE DEFAULT '2000-01-01', 
    end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    account_id UUID,
    account_code TEXT,
    account_name TEXT,
    account_type TEXT,
    total_debit NUMERIC,
    total_credit NUMERIC,
    net_balance NUMERIC
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
    SELECT 
        a.id,
        a.code,
        a.name,
        a.type,
        COALESCE(SUM(le.debit_amount), 0) as total_debit,
        COALESCE(SUM(le.credit_amount), 0) as total_credit,
        COALESCE(SUM(le.debit_amount), 0) - COALESCE(SUM(le.credit_amount), 0) as net_balance
    FROM accounts a
    LEFT JOIN ledger_entries le ON a.id = le.account_id 
        AND le.posting_date >= start_date 
        AND le.posting_date <= end_date
    GROUP BY a.id, a.code, a.name, a.type
    ORDER BY a.code;
END; $$;

-- -----------------------------------------------------------------
-- 3. TRIGGERS
-- -----------------------------------------------------------------

CREATE OR REPLACE FUNCTION prevent_ledger_modification() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN RAISE EXCEPTION 'COMPLIANCE ERROR: Ledger/Journal entries are IMMUTABLE.'; END IF;
    RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS enforce_ledger_immutability ON ledger_entries;
CREATE TRIGGER enforce_ledger_immutability BEFORE UPDATE OR DELETE ON ledger_entries FOR EACH ROW EXECUTE FUNCTION prevent_ledger_modification();

CREATE OR REPLACE FUNCTION check_period_status() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_is_closed BOOLEAN;
BEGIN
    SELECT is_closed INTO v_is_closed FROM accounting_periods WHERE start_date <= NEW.posting_date AND end_date >= NEW.posting_date;
    IF v_is_closed THEN RAISE EXCEPTION 'Accounting Period CLOSED for date %', NEW.posting_date; END IF;
    RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS prevent_closed_period_entry ON ledger_entries;
CREATE TRIGGER prevent_closed_period_entry BEFORE INSERT OR UPDATE OR DELETE ON ledger_entries FOR EACH ROW EXECUTE FUNCTION check_period_status();

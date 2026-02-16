-- =================================================================
-- CRITICAL FIXES MIGRATION - NON-NEGOTIABLE
-- Version: 1.0
-- Date: 2026-01-26
-- Purpose: Fix the 3 critical audit failures from master schema
-- Grade Impact: C+ → B+/A- (Business-Grade)
-- =================================================================

BEGIN;



-- =================================================================
-- FIX #1: REAL DOUBLE-ENTRY ENFORCEMENT (COMMIT-TIME)
-- =================================================================



-- Drop the incomplete validation function if it exists
DROP FUNCTION IF EXISTS public.validate_voucher_balance() CASCADE;

-- Create the REAL validation function (runs at COMMIT time)
CREATE OR REPLACE FUNCTION public.validate_voucher_balance_deferred()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_debit NUMERIC;
    v_credit NUMERIC;
BEGIN
    -- Calculate totals for this voucher (excluding reversed entries)
    SELECT
        COALESCE(SUM(debit_amount), 0),
        COALESCE(SUM(credit_amount), 0)
    INTO v_debit, v_credit
    FROM public.ledger_entries
    WHERE voucher_no = NEW.voucher_no
      AND COALESCE(is_reversed, false) = false;

    -- Enforce balance at 2 decimal places (accounting standard)
    IF ROUND(v_debit, 2) <> ROUND(v_credit, 2) THEN
        RAISE EXCEPTION
            'DOUBLE-ENTRY VIOLATION: Voucher % is unbalanced at COMMIT. Debit: %, Credit: %. Transaction REJECTED.',
            NEW.voucher_no, v_debit, v_credit
            USING HINT = 'Every voucher must have equal debits and credits';
    END IF;

    RETURN NULL; -- Constraint triggers return NULL
END;
$$;

-- Create the CONSTRAINT TRIGGER (deferred = runs at COMMIT)
CREATE CONSTRAINT TRIGGER enforce_voucher_balance
    AFTER INSERT OR UPDATE ON public.ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_voucher_balance_deferred();



-- =================================================================
-- FIX #2: BLOCK DIRECT LEDGER INSERTS (SOURCE ENFORCEMENT)
-- =================================================================



CREATE OR REPLACE FUNCTION public.ensure_source_document_exists()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- For sales vouchers, verify the sale exists
    IF NEW.voucher_type = 'sale' THEN
        IF NOT EXISTS (SELECT 1 FROM public.sales WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 
                'LEDGER INTEGRITY VIOLATION: Sale source document missing for voucher %. Cannot post to ledger.',
                NEW.voucher_no
                USING HINT = 'Create the sale record first, then the trigger will post to ledger automatically';
        END IF;
    END IF;

    -- For receipt/payment vouchers, verify the payment exists
    IF NEW.voucher_type IN ('receipt', 'payment') THEN
        IF NOT EXISTS (SELECT 1 FROM public.payments WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 
                'LEDGER INTEGRITY VIOLATION: Payment source document missing for voucher %. Cannot post to ledger.',
                NEW.voucher_no
                USING HINT = 'Create the payment record first, then the trigger will post to ledger automatically';
        END IF;
    END IF;

    -- For purchase vouchers, verify the purchase exists
    IF NEW.voucher_type = 'purchase' THEN
        IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 
                'LEDGER INTEGRITY VIOLATION: Purchase source document missing for voucher %. Cannot post to ledger.',
                NEW.voucher_no
                USING HINT = 'Create the purchase record first, then the trigger will post to ledger automatically';
        END IF;
    END IF;

    -- Allow other voucher types (like 'opening_balance', 'adjustment') without source validation
    -- These are typically manual journal entries by accountants
    
    RETURN NEW;
END;
$$;

CREATE TRIGGER validate_ledger_source
    BEFORE INSERT ON public.ledger_entries
    FOR EACH ROW
    EXECUTE FUNCTION public.ensure_source_document_exists();



-- =================================================================
-- FIX #3: CONCURRENCY LOCKING (PREVENT RACE CONDITIONS)
-- =================================================================



-- Recreate auto_post_sale with row locking
CREATE OR REPLACE FUNCTION public.auto_post_sale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ar_id UUID;
    v_revenue_id UUID;
    v_cash_id UUID;
BEGIN
    -- CRITICAL: Lock the party row to prevent concurrent modifications
    IF NEW.party_id IS NOT NULL THEN
        PERFORM 1 FROM public.parties WHERE id = NEW.party_id FOR UPDATE;
    END IF;
    
    -- Get account IDs
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_revenue_id FROM public.accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_cash_id FROM public.accounts WHERE slug = 'cash';
    
    IF v_ar_id IS NULL OR v_revenue_id IS NULL OR v_cash_id IS NULL THEN
        RAISE EXCEPTION 'CRITICAL: Control accounts missing for sale posting';
    END IF;
    
    -- Post to ledger based on credit/cash sale
    IF NEW.is_credit THEN
        -- Credit Sale: Dr AR, Cr Revenue
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id, NEW.total_amount, 0, 'Credit Sale - AR', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Credit Sale - Revenue', NEW.created_by);
    ELSE
        -- Cash Sale: Dr Cash, Cr Revenue
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'sale', NEW.sale_date, v_cash_id, NULL, NEW.total_amount, 0, 'Cash Sale', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Cash Sale - Revenue', NEW.created_by);
    END IF;
    
    RETURN NEW;
END;
$$;

-- Recreate auto_post_payment with row locking
CREATE OR REPLACE FUNCTION public.auto_post_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_cash_id UUID;
    v_ar_id UUID;
    v_ap_id UUID;
BEGIN
    -- CRITICAL: Lock the party row to prevent concurrent modifications
    IF NEW.party_id IS NOT NULL THEN
        PERFORM 1 FROM public.parties WHERE id = NEW.party_id FOR UPDATE;
    END IF;
    
    SELECT id INTO v_cash_id FROM public.accounts WHERE slug = 'cash';
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
    
    IF v_cash_id IS NULL OR v_ar_id IS NULL OR v_ap_id IS NULL THEN
        RAISE EXCEPTION 'CRITICAL: Control accounts missing for payment posting';
    END IF;
    
    IF NEW.payment_type = 'receipt' THEN
        -- Receipt: Dr Cash, Cr AR
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'receipt', NEW.payment_date, v_cash_id, NULL, NEW.amount, 0, 'Cash Receipt', NEW.created_by),
            (NEW.voucher_no, 'receipt', NEW.payment_date, v_ar_id, NEW.party_id, 0, NEW.amount, 'Receipt from Customer', NEW.created_by);
    ELSE
        -- Payment: Dr AP, Cr Cash
        INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES 
            (NEW.voucher_no, 'payment', NEW.payment_date, v_ap_id, NEW.party_id, NEW.amount, 0, 'Payment to Supplier', NEW.created_by),
            (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, 0, NEW.amount, 'Cash Payment', NEW.created_by);
    END IF;
    
    RETURN NEW;
END;
$$;



-- =================================================================
-- VALIDATION
-- =================================================================



DO $$
BEGIN
    -- Test that triggers exist
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger 
        WHERE tgname = 'enforce_voucher_balance'
    ) THEN
        RAISE EXCEPTION 'VALIDATION FAILED: Voucher balance trigger missing';
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger 
        WHERE tgname = 'validate_ledger_source'
    ) THEN
        RAISE EXCEPTION 'VALIDATION FAILED: Source validation trigger missing';
    END IF;
    
    RAISE NOTICE '✅ All triggers validated';
END $$;

-- =================================================================
-- COMPLETION
-- =================================================================






















COMMIT;

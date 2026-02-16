-- PHASE 5: CASH SALE & PURCHASE ATOMICITY (WALK-IN HANDLING) - POLISHED
-- -----------------------------------------------------------------
-- This migration adds RPCs to handle "Cash Transactions" atomically.
-- In Munshi Accounting, a Cash Sale = Credit Sale + Immediate Receipt.
-- This ensures the "Party" history tracks the event, even if balance change is zero.
-- Includes Robust Validation and Error Handling.

BEGIN;

-- 1. PROCESS CASH SALE
-- Wraps Insert Sale + Insert Receipt in one transaction.
CREATE OR REPLACE FUNCTION public.process_cash_sale(
    p_party_id UUID,
    p_fuel_type_id UUID,
    p_quantity NUMERIC,
    p_rate NUMERIC,
    p_total_amount NUMERIC,
    p_sale_date DATE,
    p_notes TEXT,
    p_user_id UUID
)
RETURNS JSON AS $$
DECLARE
    v_voucher_no TEXT;
    v_sale_id UUID;
    v_payment_id UUID;
BEGIN
    -- Validation
    IF p_quantity <= 0 OR p_total_amount <= 0 THEN
         RAISE EXCEPTION 'Quantity and Amount must be positive.';
    END IF;

    -- 1. Generate Voucher No (e.g., CAS-YYYYMMDD-HHMMSS)
    -- Using Time-based suffix helps ordering and uniqueness
    v_voucher_no := 'CAS-' || to_char(p_sale_date, 'YYYYMMDD') || '-' || to_char(clock_timestamp(), 'HH24MISS') || '-' || substring(md5(random()::text) from 1 for 2);

    -- 2. Insert Sale (Triggers Ledger Dr Party / Cr Revenue / Stock Out)
    INSERT INTO sales (
        voucher_no, sale_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, is_credit, notes, created_by
    ) VALUES (
        v_voucher_no, p_sale_date, p_party_id, p_fuel_type_id, p_quantity, p_rate, p_total_amount, FALSE, p_notes, p_user_id
    ) RETURNING id INTO v_sale_id;

    -- 3. Insert Payment/Receipt (Triggers Ledger Dr Cash / Cr Party)
    -- This zeroes out the party balance immediately for this transaction
    INSERT INTO payments (
        voucher_no, payment_date, payment_type, party_id, amount, method, notes, created_by
    ) VALUES (
        v_voucher_no,          -- Use SAME voucher number to link them visually
        p_sale_date, 
        'receipt', 
        p_party_id, 
        p_total_amount, 
        'Cash', 
        'Immediate Cash Settlement for Sale', 
        p_user_id
    ) RETURNING id INTO v_payment_id;

    RETURN json_build_object(
        'success', true, 
        'voucher_no', v_voucher_no, 
        'sale_id', v_sale_id, 
        'payment_id', v_payment_id
    );

EXCEPTION WHEN OTHERS THEN
    -- Return clean error JSON instead of crashing
    RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 2. PROCESS CASH PURCHASE
-- Wraps Insert Purchase + Insert Payment Out in one transaction.
CREATE OR REPLACE FUNCTION public.process_cash_purchase(
    p_party_id UUID,
    p_fuel_type_id UUID,
    p_quantity NUMERIC,
    p_rate NUMERIC,
    p_total_amount NUMERIC,
    p_purchase_date DATE,
    p_notes TEXT,
    p_user_id UUID
)
RETURNS JSON AS $$
DECLARE
    v_voucher_no TEXT;
    v_purchase_id UUID;
    v_payment_id UUID;
BEGIN
    -- Validation
    IF p_quantity <= 0 OR p_total_amount <= 0 THEN
         RAISE EXCEPTION 'Quantity and Amount must be positive.';
    END IF;

    -- 1. Generate Voucher No (e.g., CAP-YYYYMMDD-HHMMSS)
    v_voucher_no := 'CAP-' || to_char(p_purchase_date, 'YYYYMMDD') || '-' || to_char(clock_timestamp(), 'HH24MISS') || '-' || substring(md5(random()::text) from 1 for 2);

    -- 2. Insert Purchase (Triggers Ledger Dr Purchase / Cr Party / Stock In)
    INSERT INTO purchases (
        voucher_no, purchase_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, is_paid_now, notes, created_by
    ) VALUES (
        v_voucher_no, p_purchase_date, p_party_id, p_fuel_type_id, p_quantity, p_rate, p_total_amount, TRUE, p_notes, p_user_id
    ) RETURNING id INTO v_purchase_id;

    -- 3. Insert Payment Out (Triggers Ledger Dr Party / Cr Cash)
    INSERT INTO payments (
        voucher_no, payment_date, payment_type, party_id, amount, method, notes, created_by
    ) VALUES (
        v_voucher_no,          -- Use SAME voucher number
        p_purchase_date, 
        'payment',             -- Outflow
        p_party_id, 
        p_total_amount, 
        'Cash', 
        'Immediate Cash Payment for Purchase', 
        p_user_id
    ) RETURNING id INTO v_payment_id;

    RETURN json_build_object(
        'success', true, 
        'voucher_no', v_voucher_no, 
        'purchase_id', v_purchase_id, 
        'payment_id', v_payment_id
    );

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;

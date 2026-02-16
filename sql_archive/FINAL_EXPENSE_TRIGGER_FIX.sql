-- =================================================================
-- TRIGGER BYPASS & EXPENSE FIX (Jan 30, 2026)
-- Target: Fix "Source Missing" error for expenses
-- =================================================================

BEGIN;

-- 1. Update the Trigger Function to allow Direct Expenses
-- Direct expenses (no party_id) do not need a record in the 'payments' table
CREATE OR REPLACE FUNCTION public.ensure_source_document_exists()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- [A] WHITELIST VALIDATION
    IF NEW.voucher_type NOT IN (
        'sale', 'purchase', 'receipt', 'payment', 
        'opening_balance', 'transfer', 'journal'
    ) THEN
        RAISE EXCEPTION 'INVALID VOUCHER TYPE: "%"', NEW.voucher_type;
    END IF;

    -- [B] SOURCE VALIDATION (Only for sub-ledger integrated types)
    
    -- For Sales: Always need a source
    IF NEW.voucher_type = 'sale' THEN
        IF NOT EXISTS (SELECT 1 FROM public.sales WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 'Source missing for sale voucher %', NEW.voucher_no;
        END IF;
    END IF;

    -- For Purchases: Always need a source
    IF NEW.voucher_type = 'purchase' THEN
        IF NOT EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 'Source missing for purchase voucher %', NEW.voucher_no;
        END IF;
    END IF;

    -- For Receipts/Payments: Only need source IF a Party is involved
    -- Expenses are direct GL entries and have NULL party_id
    IF NEW.voucher_type IN ('receipt', 'payment') AND NEW.party_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.payments WHERE voucher_no = NEW.voucher_no) THEN
            RAISE EXCEPTION 'Source missing for payment/receipt voucher % (Party involved)', NEW.voucher_no;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;

-- 2. Final Fix for post_expense_entry (Ensure it uses consistent format)
CREATE OR REPLACE FUNCTION public.post_expense_entry(
    p_expense_account_id UUID,
    p_payment_account_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE
) RETURNS json 
LANGUAGE plpgsql 
SECURITY DEFINER 
AS $$
DECLARE
    v_voucher_no TEXT;
    v_seq_num BIGINT;
    v_date_str TEXT;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    
    v_date_str := to_char(COALESCE(p_date, CURRENT_DATE), 'YYYYMMDD');
    SELECT nextval('public.voucher_seq_payment_v2') INTO v_seq_num;
    v_voucher_no := 'EXP-' || v_date_str || '-' || lpad(v_seq_num::text, 4, '0');

    -- DEBIT: Expense (party_id is NULL)
    INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, party_id,
        debit_amount, credit_amount, narration, created_by, quantity, rate
    )
    VALUES (v_voucher_no, 'payment', p_date, p_expense_account_id, NULL, p_amount, 0, p_narration, auth.uid(), 0, 0);

    -- CREDIT: Cash/Bank (party_id is NULL)
    INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, party_id,
        debit_amount, credit_amount, narration, created_by, quantity, rate
    )
    VALUES (v_voucher_no, 'payment', p_date, p_payment_account_id, NULL, 0, p_amount, p_narration, auth.uid(), 0, 0);

    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END;
$$;

COMMIT;

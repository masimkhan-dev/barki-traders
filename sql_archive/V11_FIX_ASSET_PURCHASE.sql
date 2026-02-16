
-- V11 FIX ASSET PURCHASE RPC
-- Purpose: Resolve "null value in column account_id" error by ensuring correct account creation and ledger posting.

-- 1. Ensure `sub_category` exists in accounts (it likely does, but purely for safety)
DO $$ 
BEGIN 
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='accounts' AND column_name='sub_category') THEN
        ALTER TABLE public.accounts ADD COLUMN sub_category TEXT;
    END IF;
END $$;

-- 2. Create the Function
CREATE OR REPLACE FUNCTION public.purchase_fixed_asset(
    p_name TEXT,
    p_category TEXT,
    p_amount NUMERIC,
    p_date DATE,
    p_paid_from_account_id UUID,
    p_description TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_asset_account_id UUID;
    v_voucher_no TEXT;
    v_new_code TEXT;
    v_max_code INTEGER;
BEGIN
    -- A. Generate a new Account Code for the Fixed Asset
    -- Find the highest existing code that is numeric, assuming Assets are 1000-1999 range usually, but we just want a unique one.
    -- We'll try to find max numeric code and add 1.
    -- If fails, fallback to a timestamp based code.
    
    BEGIN
        SELECT MAX(code::INTEGER) INTO v_max_code 
        FROM public.accounts 
        WHERE code ~ '^[0-9]+$';
        
        IF v_max_code IS NULL THEN 
            v_max_code := 10000; -- Fallback start
        END IF;
        
        v_new_code := (v_max_code + 1)::TEXT;
    EXCEPTION WHEN OTHERS THEN
        v_new_code := 'FA-' || to_char(now(), 'MMDDSS');
    END;

    -- B. Create the Fixed Asset Account
    INSERT INTO public.accounts (
        name, 
        code, 
        account_type, 
        sub_category, 
        is_active, 
        is_system, 
        created_at
    ) VALUES (
        p_name,
        v_new_code,
        'asset',
        p_category, -- e.g. 'Machinery', 'Vehicle'
        true,
        false,
        NOW()
    )
    RETURNING id INTO v_asset_account_id;

    -- C. Generate Voucher Number
    -- Format: EXP-YYYYMMDD-XXXX
    v_voucher_no := 'EXP-' || to_char(p_date, 'YYYYMMDD') || '-' || substring(md5(random()::text) from 1 for 4);

    -- D. Check for valid Payment Account
    IF p_paid_from_account_id IS NULL THEN
        RAISE EXCEPTION 'Payment Source Account ID is required';
    END IF;

    -- E. Insert Ledger Entries (Double Entry)
    
    -- 1. DEBIT: New Asset Account (Increase Asset)
    INSERT INTO public.ledger_entries (
        voucher_no,
        voucher_type,
        posting_date,
        account_id,
        debit_amount,
        credit_amount,
        narration,
        created_by
    ) VALUES (
        v_voucher_no,
        'payment',  -- or 'expense' or 'journal'? Expenses.tsx uses 'payment' in fetch query, implies 'payment'.
        p_date,
        v_asset_account_id,
        p_amount,
        0,
        p_description,
        auth.uid()
    );

    -- 2. CREDIT: Cash/Bank (Decrease Asset)
    INSERT INTO public.ledger_entries (
        voucher_no,
        voucher_type,
        posting_date,
        account_id,
        debit_amount,
        credit_amount,
        narration,
        created_by
    ) VALUES (
        v_voucher_no,
        'payment',
        p_date,
        p_paid_from_account_id,
        0,
        p_amount,
        p_description,
        auth.uid()
    );

    RETURN jsonb_build_object(
        'success', true,
        'voucher_no', v_voucher_no,
        'asset_account_id', v_asset_account_id
    );
END;
$$;

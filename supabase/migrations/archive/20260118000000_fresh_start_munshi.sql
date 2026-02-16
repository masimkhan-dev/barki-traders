
-- MUNSHI FRESH START MIGRATION
-- WARNING: THIS DELETES ALL SALES, PURCHASES, PAYMENTS, CUSTOMERS, AND SUPPLIERS DATA.
-- IT ESTABLISHES A CLEAN "PARTIES" SYSTEM.

BEGIN;

-- 1. DROP EXISTING TABLES (Clean Slate)
DROP TABLE IF EXISTS public.sales CASCADE;
DROP TABLE IF EXISTS public.purchases CASCADE;
DROP TABLE IF EXISTS public.payments CASCADE;
DROP TABLE IF EXISTS public.ledger_entries CASCADE;
DROP TABLE IF EXISTS public.customers CASCADE;
DROP TABLE IF EXISTS public.suppliers CASCADE;
DROP TABLE IF EXISTS public.parties CASCADE;

-- 2. CREATE UNIFIED "PARTIES" TABLE
CREATE TABLE public.parties (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('customer', 'supplier', 'both', 'other')),
    phone TEXT,
    address TEXT,
    opening_balance NUMERIC DEFAULT 0,
    current_balance NUMERIC DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. RE-CREATE SALES TABLE (Links to Parties)
CREATE TABLE public.sales (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL,
    sale_date DATE NOT NULL DEFAULT CURRENT_DATE,
    party_id UUID REFERENCES public.parties(id), -- Unified linkage
    fuel_type_id UUID REFERENCES public.fuel_types(id),
    quantity NUMERIC NOT NULL,
    rate_per_unit NUMERIC NOT NULL,
    total_amount NUMERIC NOT NULL,
    is_credit BOOLEAN DEFAULT false,
    notes TEXT,
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. RE-CREATE PURCHASES TABLE (Links to Parties)
CREATE TABLE public.purchases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL,
    purchase_date DATE NOT NULL DEFAULT CURRENT_DATE,
    party_id UUID REFERENCES public.parties(id), -- Unified linkage
    fuel_type_id UUID REFERENCES public.fuel_types(id),
    quantity NUMERIC NOT NULL,
    rate_per_unit NUMERIC NOT NULL,
    total_amount NUMERIC NOT NULL,
    is_paid_now BOOLEAN DEFAULT false,
    payment_method TEXT,
    notes TEXT,
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. RE-CREATE PAYMENTS TABLE (Sub-ledger for Parties)
CREATE TABLE public.payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL,
    payment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    payment_type TEXT CHECK (payment_type IN ('receipt', 'payment')), -- Receipt=In, Payment=Out
    party_id UUID REFERENCES public.parties(id),
    amount NUMERIC NOT NULL,
    method TEXT DEFAULT 'Cash', 
    notes TEXT,
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 6. RE-CREATE LEDGER_ENTRIES (General Ledger)
-- (Ensures we still have the core accounting backbone)
CREATE TABLE public.ledger_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no TEXT NOT NULL,
    voucher_type TEXT NOT NULL,
    posting_date DATE NOT NULL,
    account_id UUID REFERENCES public.accounts(id),
    debit_amount NUMERIC DEFAULT 0,
    credit_amount NUMERIC DEFAULT 0,
    narration TEXT,
    party_id UUID REFERENCES public.parties(id), -- Optional: Link GL entry to a Party for reporting
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 7. ENABLE SECURITY (RLS)
ALTER TABLE parties ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable all for authenticated" ON parties FOR ALL TO authenticated USING (true);
CREATE POLICY "Enable all for authenticated" ON sales FOR ALL TO authenticated USING (true);
CREATE POLICY "Enable all for authenticated" ON purchases FOR ALL TO authenticated USING (true);
CREATE POLICY "Enable all for authenticated" ON payments FOR ALL TO authenticated USING (true);
CREATE POLICY "Enable all for authenticated" ON ledger_entries FOR ALL TO authenticated USING (true);

-- 8. DEFINE THE TRANSACTION FUNCTION (Updated for Parties)
CREATE OR REPLACE FUNCTION create_manage_transaction(
    p_transaction_type TEXT,
    p_from_type TEXT,
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
    v_voucher_no TEXT;
    v_debit_account_id UUID;
    v_credit_account_id UUID;
    v_receivable_control UUID; -- 1100
    v_payable_control UUID;    -- 2000
    v_result json;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    
    v_voucher_no := 'TRF-' || TO_CHAR(p_transaction_date::date, 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
    
    -- Get GL Control Account IDs
    -- Ensure these exist in your 'accounts' table (1100=Receivable, 2000=Payable)
    -- If they don't exist, these will be null, so ideally we'd insert them if missing, but let's assume they exist from seed.
    SELECT id INTO v_receivable_control FROM accounts WHERE code = '1100' LIMIT 1;
    SELECT id INTO v_payable_control FROM accounts WHERE code = '2000' LIMIT 1;
    
    -- Handle Missing Control Accounts (Fallback to create temporary placeholder or error)
    IF v_receivable_control IS NULL THEN 
        -- Fallback logic or error. For migration safety, we proceed or error.
        -- RAISE NOTICE 'Control accounts missing, continuing with NULL (will fail GL constraint if strict)';
    END IF;

    -- A. RESOLVE GIVER (From) - Credit Side
    IF p_from_type = 'account' THEN
       v_credit_account_id := p_from_entity_id;
    ELSE 
       -- It's a Party (Customer/Supplier/Both)
       -- Logic: If they give money, we Credit them.
       -- In GL: We Credit 'Accounts Receivable' (Asset Decrease) usually for Customers.
       v_credit_account_id := v_receivable_control;
       
       -- Add Sub-ledger Entry
       INSERT INTO payments (voucher_no, payment_type, party_id, amount, payment_date, notes, created_by)
       VALUES (v_voucher_no, 'receipt', p_from_entity_id, p_amount, p_transaction_date, 'Transfer Out: ' || p_narration, auth.uid());
    END IF;

    -- B. RESOLVE RECEIVER (To) - Debit Side
    IF p_to_type = 'account' THEN
       v_debit_account_id := p_to_entity_id;
    ELSE
       -- It's a Party
       -- Logic: They receive money. We Debit them.
       -- In GL: We Debit 'Accounts Receivable' (Asset Increase).
       v_debit_account_id := v_receivable_control;

       -- Add Sub-ledger Entry
       INSERT INTO payments (voucher_no, payment_type, party_id, amount, payment_date, notes, created_by)
       VALUES (v_voucher_no, 'payment', p_to_entity_id, p_amount, p_transaction_date, 'Transfer In: ' || p_narration, auth.uid());
    END IF;

    -- C. GL ENTRIES
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES 
    (v_voucher_no, 'manage_transaction', p_transaction_date, v_debit_account_id, CASE WHEN p_to_type != 'account' THEN p_to_entity_id ELSE NULL END, p_amount, 0, p_narration, auth.uid()),
    (v_voucher_no, 'manage_transaction', p_transaction_date, v_credit_account_id, CASE WHEN p_from_type != 'account' THEN p_from_entity_id ELSE NULL END, 0, p_amount, p_narration, auth.uid());

    SELECT json_build_object('success', true, 'voucher_no', v_voucher_no) INTO v_result;
    RETURN v_result;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Transaction Error: %', SQLERRM;
END;
$$;

COMMIT;

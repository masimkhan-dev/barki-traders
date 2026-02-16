-- =================================================================
-- FIX: Opening Balance — Complete Solution
-- 
-- PROBLEM 1: Trigger ignores opening_balance when recalculating
--            current_balance → parties.current_balance drifts
--
-- PROBLEM 2: Trial Balance out by Rs 80,090 because fareq han's
--            opening_balance exists in parties table but NOT in
--            ledger_entries. No contra entry → TB doesn't balance.
--
-- SOLUTION: 
--   Step 1: Fix the trigger to include opening_balance
--   Step 2: Post proper ledger entries for ALL party opening balances
--   Step 3: Zero out parties.opening_balance (it's now in ledger)
--   Step 4: Recalculate all current_balance values
--
-- IMPORTANT: get_party_statement already handles this correctly:
--   opening = parties.opening_balance + SUM(ledger before date)
--   After this fix, opening_balance=0 and the ledger entry takes over.
--
-- RUN THIS IN SUPABASE SQL EDITOR
-- =================================================================

BEGIN;

-- =================================================================
-- STEP 1: Fix the trigger function
-- =================================================================
CREATE OR REPLACE FUNCTION public.update_party_balance_on_ledger_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    -- On DELETE or UPDATE (old party)
    IF (TG_OP = 'DELETE' OR TG_OP = 'UPDATE') THEN
        IF (OLD.party_id IS NOT NULL) THEN
            UPDATE public.parties 
            SET current_balance = (
                COALESCE(opening_balance, 0) +
                COALESCE((
                    SELECT SUM(debit_amount) - SUM(credit_amount)
                    FROM public.ledger_entries WHERE party_id = OLD.party_id
                ), 0)
            ) WHERE id = OLD.party_id;
        END IF;
    END IF;

    -- On INSERT or UPDATE (new party)
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        IF (NEW.party_id IS NOT NULL) THEN
            UPDATE public.parties 
            SET current_balance = (
                COALESCE(opening_balance, 0) +
                COALESCE((
                    SELECT SUM(debit_amount) - SUM(credit_amount)
                    FROM public.ledger_entries WHERE party_id = NEW.party_id
                ), 0)
            ) WHERE id = NEW.party_id;
        END IF;
    END IF;

    RETURN NULL;
END; $$;

-- Ensure trigger is attached
DROP TRIGGER IF EXISTS trg_sync_party_balance ON public.ledger_entries;
DROP TRIGGER IF EXISTS trg_sync_party_balance_strict ON public.ledger_entries;

CREATE TRIGGER trg_sync_party_balance
AFTER INSERT OR UPDATE OR DELETE ON public.ledger_entries
FOR EACH ROW EXECUTE FUNCTION public.update_party_balance_on_ledger_change();


-- =================================================================
-- STEP 2: Post opening balances as proper double-entry ledger entries
-- This fixes the Trial Balance mismatch
-- =================================================================

DO $$
DECLARE
    party_rec RECORD;
    v_ar_id UUID;
    v_ap_id UUID;
    v_capital_id UUID;
    v_voucher TEXT;
    v_date DATE := '2026-01-30';  -- Day before your accounting start
    v_count INT := 0;
BEGIN
    -- Lookup control accounts
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
    SELECT id INTO v_capital_id FROM public.accounts WHERE slug = 'capital';

    IF v_ar_id IS NULL OR v_ap_id IS NULL OR v_capital_id IS NULL THEN
        RAISE EXCEPTION 'Missing control accounts (ar, ap, or capital). Cannot proceed.';
    END IF;

    -- Loop through all parties with non-zero opening_balance
    FOR party_rec IN
        SELECT id, name, type, opening_balance
        FROM public.parties
        WHERE COALESCE(opening_balance, 0) != 0
    LOOP
        -- Generate unique voucher number
        v_voucher := 'OB-' || UPPER(SUBSTRING(party_rec.name, 1, 3)) || '-' || SUBSTRING(party_rec.id::TEXT, 1, 8);

        -- Skip if already posted
        IF EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = v_voucher) THEN
            RAISE NOTICE 'SKIP: % (already posted as %)', party_rec.name, v_voucher;
            CONTINUE;
        END IF;

        IF party_rec.opening_balance > 0 THEN
            -- Positive = Party owes us (Receivable)
            -- Dr: Accounts Receivable (with party_id)
            -- Cr: Owner's Capital (contra)
            INSERT INTO public.ledger_entries 
                (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
            VALUES
                (v_voucher, 'opening', v_date, v_ar_id, party_rec.id, 
                 party_rec.opening_balance, 0, 
                 'Opening Balance - ' || party_rec.name || ' (Receivable)', auth.uid()),
                (v_voucher, 'opening', v_date, v_capital_id, NULL, 
                 0, party_rec.opening_balance, 
                 'Opening Balance - ' || party_rec.name || ' (Contra)', auth.uid());

        ELSIF party_rec.opening_balance < 0 THEN
            -- Negative = We owe party (Payable)
            -- Dr: Owner's Capital (contra)
            -- Cr: Accounts Payable (with party_id)
            INSERT INTO public.ledger_entries 
                (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
            VALUES
                (v_voucher, 'opening', v_date, v_capital_id, NULL, 
                 ABS(party_rec.opening_balance), 0, 
                 'Opening Balance - ' || party_rec.name || ' (Contra)', auth.uid()),
                (v_voucher, 'opening', v_date, v_ap_id, party_rec.id, 
                 0, ABS(party_rec.opening_balance), 
                 'Opening Balance - ' || party_rec.name || ' (Payable)', auth.uid());
        END IF;

        v_count := v_count + 1;
        RAISE NOTICE 'POSTED: % → % (Rs %)', party_rec.name, v_voucher, party_rec.opening_balance;
    END LOOP;

    RAISE NOTICE '---------------------------------------------';
    RAISE NOTICE 'Total opening balances posted: %', v_count;
END $$;


-- =================================================================
-- STEP 3: Zero out parties.opening_balance 
-- (it's now in the ledger — no more double-counting)
-- =================================================================

UPDATE public.parties
SET opening_balance = 0
WHERE COALESCE(opening_balance, 0) != 0;


-- =================================================================
-- STEP 4: Recalculate ALL party current_balance values
-- =================================================================

UPDATE public.parties p
SET current_balance = (
    COALESCE(p.opening_balance, 0) +
    COALESCE((
        SELECT SUM(le.debit_amount) - SUM(le.credit_amount)
        FROM public.ledger_entries le 
        WHERE le.party_id = p.id 
          AND le.is_reversed = false
    ), 0)
);


-- =================================================================
-- STEP 5: VERIFICATION
-- =================================================================

-- Check 1: Show migrated opening balance entries
SELECT voucher_no, posting_date, narration, debit_amount, credit_amount
FROM public.ledger_entries
WHERE voucher_type = 'opening'
ORDER BY voucher_no;

-- Check 2: Verify no parties have non-zero opening_balance
SELECT name, opening_balance 
FROM public.parties 
WHERE COALESCE(opening_balance, 0) != 0;
-- Should return 0 rows

-- Check 3: Trial Balance check (should be 0.00)
SELECT 
    ROUND(SUM(debit_amount) - SUM(credit_amount), 2) as trial_balance_diff,
    CASE 
        WHEN ABS(SUM(debit_amount) - SUM(credit_amount)) < 0.01 
        THEN '✅ TRIAL BALANCE IS BALANCED!'
        ELSE '❌ STILL OUT BY: Rs ' || ROUND(SUM(debit_amount) - SUM(credit_amount), 2)::TEXT
    END as status
FROM public.ledger_entries
WHERE is_reversed = false;


-- =================================================================
-- STEP 6: Create RPC for future party opening balances
-- Called by QuickAddCustomer when opening_balance is non-zero
-- =================================================================

CREATE OR REPLACE FUNCTION public.initialize_party_opening_balance(
    p_party_id UUID,
    p_opening_balance NUMERIC,
    p_opening_date DATE DEFAULT CURRENT_DATE
)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ar_id UUID;
    v_ap_id UUID;
    v_capital_id UUID;
    v_voucher TEXT;
    v_party_name TEXT;
BEGIN
    -- Skip zero balances
    IF COALESCE(p_opening_balance, 0) = 0 THEN
        RETURN 'SKIP: Zero opening balance';
    END IF;

    -- Get party name
    SELECT name INTO v_party_name FROM public.parties WHERE id = p_party_id;
    IF v_party_name IS NULL THEN
        RAISE EXCEPTION 'Party not found: %', p_party_id;
    END IF;

    -- Lookup control accounts
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
    SELECT id INTO v_capital_id FROM public.accounts WHERE slug = 'capital';

    IF v_ar_id IS NULL OR v_ap_id IS NULL OR v_capital_id IS NULL THEN
        RAISE EXCEPTION 'Missing control accounts (ar, ap, or capital)';
    END IF;

    -- Generate voucher number
    v_voucher := 'OB-' || UPPER(SUBSTRING(v_party_name, 1, 3)) || '-' || SUBSTRING(p_party_id::TEXT, 1, 8);

    -- Check for duplicate
    IF EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = v_voucher) THEN
        RETURN 'ERROR: Opening balance already posted for this party';
    END IF;

    IF p_opening_balance > 0 THEN
        -- Party owes us → Dr: AR, Cr: Capital
        INSERT INTO public.ledger_entries
            (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES
            (v_voucher, 'opening', p_opening_date, v_ar_id, p_party_id,
             p_opening_balance, 0,
             'Opening Balance - ' || v_party_name || ' (Receivable)', auth.uid()),
            (v_voucher, 'opening', p_opening_date, v_capital_id, NULL,
             0, p_opening_balance,
             'Opening Balance - ' || v_party_name || ' (Contra)', auth.uid());
    ELSE
        -- We owe party → Dr: Capital, Cr: AP
        INSERT INTO public.ledger_entries
            (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES
            (v_voucher, 'opening', p_opening_date, v_capital_id, NULL,
             ABS(p_opening_balance), 0,
             'Opening Balance - ' || v_party_name || ' (Contra)', auth.uid()),
            (v_voucher, 'opening', p_opening_date, v_ap_id, p_party_id,
             0, ABS(p_opening_balance),
             'Opening Balance - ' || v_party_name || ' (Payable)', auth.uid());
    END IF;

    RETURN 'SUCCESS: Posted voucher ' || v_voucher;
END; $$;


COMMIT;


-- =========================================================
-- DIAGNOSTIC V2: CHECK SPECIFIC VOUCHER EXP-20260130-0007
-- =========================================================

DO $$
DECLARE
    r RECORD;
BEGIN
    RAISE NOTICE '---------------------------------------------------';
    RAISE NOTICE '🔍 INSPECTING VOUCHER: EXP-20260130-0007';
    RAISE NOTICE '---------------------------------------------------';

    FOR r IN 
        SELECT 
            le.id,
            le.debit_amount,
            le.credit_amount,
            a.name as account_name,
            a.account_type as account_type,
            a.code as account_code,
            le.is_reversed
        FROM public.ledger_entries le
        JOIN public.accounts a ON a.id = le.account_id
        WHERE le.voucher_no = 'EXP-20260130-0007'
    LOOP
        RAISE NOTICE 'Entry Found: Account="%" (Type=%) | Dr=% | Cr=% | Reversed=%', 
            r.account_name, r.account_type, r.debit_amount, r.credit_amount, COALESCE(r.is_reversed, false);
            
        -- CHECK FOR PROBLEM
        IF r.debit_amount > 0 AND r.account_type != 'expense' THEN
             RAISE NOTICE '❌ PROBLEM DETECTED: This is the DEBIT entry (The Cost), but Account Type is "%" (not "expense").', r.account_type;
             RAISE NOTICE '🛠 ACTION: Running AUTO-FIX on Account "%"...', r.account_name;
             
             UPDATE public.accounts 
             SET account_type = 'expense' 
             WHERE name = r.account_name;
             
             RAISE NOTICE '✅ FIXED: Account type updated to "expense".';
        END IF;
        
    END LOOP;
    
    RAISE NOTICE '---------------------------------------------------';
END $$;

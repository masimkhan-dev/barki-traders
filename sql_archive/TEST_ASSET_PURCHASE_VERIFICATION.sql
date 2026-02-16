
-- TEST SCRIPT: VERIFY FIXED ASSET PURCHASE
-- Purpose: Verify that the 'solar panel' asset was created and the transaction was posted correctly.

DO $$
DECLARE
    v_asset_name TEXT := 'solar panel'; -- The name used in the user's request
    v_asset_account_id UUID;
    v_asset_val NUMERIC;
    v_debit_entry RECORD;
    v_credit_entry RECORD;
    v_entries_count INT;
BEGIN
    RAISE NOTICE '===================================================';
    RAISE NOTICE '       VERIFYING FIXED ASSET PURCHASE              ';
    RAISE NOTICE '===================================================';

    -- 1. Verify Asset Account Creation
    SELECT id INTO v_asset_account_id
    FROM public.accounts 
    WHERE name ILIKE v_asset_name AND account_type = 'asset';

    IF v_asset_account_id IS NULL THEN
        RAISE NOTICE '❌ FAILED: Asset Account "%" NOT FOUND.', v_asset_name;
    ELSE
        RAISE NOTICE '✅ SUCCESS: Asset Account "%" exists (ID: %).', v_asset_name, v_asset_account_id;
    END IF;

    -- 2. Verify Ledger Entries for this Account
    -- We look for the debit entry in the asset account
    SELECT count(*) INTO v_entries_count
    FROM public.ledger_entries 
    WHERE account_id = v_asset_account_id;

    IF v_entries_count = 0 THEN
        RAISE NOTICE '❌ FAILED: No ledger entries found for this asset.';
    ELSE
        RAISE NOTICE '✅ SUCCESS: Found % ledger entry/entries for the asset.', v_entries_count;
        
        -- Get the details of the latest entry
        SELECT * INTO v_debit_entry
        FROM public.ledger_entries 
        WHERE account_id = v_asset_account_id
        ORDER BY created_at DESC 
        LIMIT 1;

        RAISE NOTICE '   -> Debit Entry Voucher: %, Amount: %', v_debit_entry.voucher_no, v_debit_entry.debit_amount;

        -- 3. Verify the Offset Credit Entry (Double Entry)
        -- It should have the same voucher_no but credit amount > 0
        SELECT * INTO v_credit_entry
        FROM public.ledger_entries 
        WHERE voucher_no = v_debit_entry.voucher_no 
          AND credit_amount > 0;

        IF v_credit_entry.id IS NULL THEN
             RAISE NOTICE '❌ FAILED: Double-entry NOT FOUND. Missing Credit leg.';
        ELSE
             RAISE NOTICE '✅ SUCCESS: Double-entry integrity confirmed.';
             RAISE NOTICE '   -> Credit Entry Account ID: %, Amount: %', v_credit_entry.account_id, v_credit_entry.credit_amount;
             
             IF v_credit_entry.credit_amount = v_debit_entry.debit_amount THEN
                 RAISE NOTICE '✅ SUCCESS: Amounts match exactly (Balanced).';
             ELSE
                 RAISE NOTICE '❌ FAILED: Amounts DO NOT match (Unbalanced).';
             END IF;
        END IF;

    END IF;

    RAISE NOTICE '===================================================';
END $$;

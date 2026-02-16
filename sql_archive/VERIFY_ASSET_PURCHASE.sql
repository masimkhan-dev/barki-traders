
-- VERIFY ASSET PURCHASE CONFIGURATION
-- Purpose: Check if the necessary function and columns exist before applying fix.

DO $$
DECLARE
    v_func_exists BOOLEAN;
    v_col_exists BOOLEAN;
    v_func_args TEXT;
BEGIN
    -- 1. Check Function Existence
    SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'purchase_fixed_asset') INTO v_func_exists;
    
    -- 2. Check Arguments (if it exists)
    SELECT pg_get_function_arguments(oid) INTO v_func_args
    FROM pg_proc 
    WHERE proname = 'purchase_fixed_asset';

    -- 3. Check Account Column
    SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='accounts' AND column_name='sub_category') INTO v_col_exists;

    RAISE NOTICE '---------------------------------------------------';
    RAISE NOTICE 'DIAGNOSTIC RESULTS';
    RAISE NOTICE '---------------------------------------------------';
    RAISE NOTICE 'Function purchase_fixed_asset exists   : %', v_func_exists;
    IF v_func_exists THEN
        RAISE NOTICE 'Function Arguments                     : %', v_func_args;
    END IF;
    RAISE NOTICE 'Column accounts.sub_category exists    : %', v_col_exists;
    RAISE NOTICE '---------------------------------------------------';

    IF NOT v_func_exists THEN
         RAISE NOTICE 'RESULT: The function is MISSING. The fix script MUST be run.';
    ELSIF NOT v_col_exists THEN
         RAISE NOTICE 'RESULT: The sub_category column is MISSING. The fix script handles this.';
    ELSE
         RAISE NOTICE 'RESULT: Function exists but may be buggy. Safe to overwrite with fix.';
    END IF;
END $$;

-- ============================================================================
-- SUPABASE-COMPATIBLE RECONCILIATION SCRIPT
-- ============================================================================

DO $$
DECLARE
    v_net_profit NUMERIC;
    v_total_assets NUMERIC;
    v_total_equity_liabilities NUMERIC;
    v_difference NUMERIC;
    r RECORD;
BEGIN
    RAISE NOTICE '===================================================================';
    RAISE NOTICE 'STEP 1: Recalculate All Party Balances';
    RAISE NOTICE '===================================================================';
    
    FOR r IN SELECT id FROM parties WHERE is_active = true LOOP
        -- We are calling your existing function to get fresh balance
        UPDATE parties
        SET current_balance = recalculate_party_balance(r.id)
        WHERE id = r.id;
    END LOOP;

    RAISE NOTICE '✅ Party balances updated.';

    RAISE NOTICE '===================================================================';
    RAISE NOTICE 'STEP 2: Recalculate Profit / Loss';
    RAISE NOTICE '===================================================================';
    
    -- Calculate Net Profit strictly from Income/Expense accounts
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_net_profit
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND COALESCE(le.is_reversed, false) = false;

    RAISE NOTICE '✅ Calculated Net Profit: %', v_net_profit;

    RAISE NOTICE '===================================================================';
    RAISE NOTICE 'STEP 3: Verify Accounting Equation';
    RAISE NOTICE '===================================================================';

    -- 1. Total Assets
    SELECT COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    INTO v_total_assets
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND COALESCE(le.is_reversed, false) = false;
      
    -- Add Party Receivables (Debit Balances)
    v_total_assets := v_total_assets + (
        SELECT COALESCE(SUM(recalculate_party_balance(id)), 0)
        FROM parties
        WHERE recalculate_party_balance(id) > 0
    );

    -- 2. Total Equity & Liabilities
    -- Owner's Equity (Capital)
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_total_equity_liabilities
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'equity'
      AND COALESCE(le.is_reversed, false) = false;

    -- Add Liabilities (Credit Balances from Parties)
    v_total_equity_liabilities := v_total_equity_liabilities + (
        SELECT ABS(COALESCE(SUM(recalculate_party_balance(id)), 0))
        FROM parties
        WHERE recalculate_party_balance(id) < 0
    );

    -- Add Net Profit (Retained Earnings)
    v_total_equity_liabilities := v_total_equity_liabilities + v_net_profit;

    v_difference := v_total_assets - v_total_equity_liabilities;

    RAISE NOTICE 'Total Assets: %', v_total_assets;
    RAISE NOTICE 'Total Liabilities + Equity: %', v_total_equity_liabilities;
    RAISE NOTICE 'Difference: %', v_difference;

    IF v_difference = 0 THEN
        RAISE NOTICE '✅ SUCCESS: BALANCE SHEET IS MATCHED!';
    ELSE
        RAISE NOTICE '❌ MISMATCH DETECTED: Rs. %', v_difference;
    END IF;

END $$;

-- STEP 4: FINAL REPORT (Run this to see the breakdown)
SELECT 
    'Assets' as Category, 
    SUM(CASE WHEN recalculate_party_balance(id) > 0 THEN recalculate_party_balance(id) ELSE 0 END) +
    (SELECT COALESCE(SUM(le.debit_amount - le.credit_amount), 0) 
     FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
     WHERE a.account_type = 'asset' AND COALESCE(le.is_reversed, false) = false) 
    as Amount
FROM parties
UNION ALL
SELECT 
    'Liabilities + Equity',
    ABS(SUM(CASE WHEN recalculate_party_balance(id) < 0 THEN recalculate_party_balance(id) ELSE 0 END)) +
    (SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0) 
     FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
     WHERE a.account_type = 'equity' AND COALESCE(le.is_reversed, false) = false) +
    (SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0) 
     FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
     WHERE a.account_type IN ('income', 'expense') AND COALESCE(le.is_reversed, false) = false)
FROM parties;

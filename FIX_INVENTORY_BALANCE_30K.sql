-- ==============================================================================
-- FIX SCRIPT: CLEAR INVENTORY (CONTROL) RESIDUAL BALANCE (-30,000)
-- Purpose: Safely writes off the Rs 30,000 negative balance in Inventory Control 
--          caused by the exact rate discrepancy on 3rd March 2026.
-- Method:  Debits Inventory Control to bring it up to 0, and Credits Cost of 
--          Goods Sold (COGS) to reverse the over-expense.
-- ==============================================================================

DO $$
DECLARE
    v_inventory_acc uuid;
    v_expense_acc uuid;
    v_voucher text := 'ADJ-' || TO_CHAR(NOW(), 'YYYYMMDD-HH24MI');
    v_balance numeric := 30000.00;
BEGIN
    -- 1. Find Inventory Control Account ID
    SELECT id INTO v_inventory_acc FROM accounts 
    WHERE slug = 'inventory_control' OR name ILIKE '%Inventory%Control%' LIMIT 1;

    -- 2. Find Cost of Goods Sold (COGS) Account ID to absorb the value mismatch
    SELECT id INTO v_expense_acc FROM accounts 
    WHERE slug = 'cost_of_goods_sold' OR name ILIKE '%Cost of Goods%' LIMIT 1;
    
    -- Fallback: If COGS doesn't exist, use Owner's Capital/Equity
    IF v_expense_acc IS NULL THEN
        SELECT id INTO v_expense_acc FROM accounts 
        WHERE slug = 'owner_capital' OR name ILIKE '%Capital%' LIMIT 1;
    END IF;

    -- SAFEGUARD: Only run if we found the accounts
    IF v_inventory_acc IS NOT NULL AND v_expense_acc IS NOT NULL THEN
        
        -- Insert Balancing Entry to Fix Negative 30,000
        INSERT INTO ledger_entries 
        (voucher_no, voucher_type, account_id, debit_amount, credit_amount, posting_date, narration, is_reversed)
        VALUES 
        -- Debit Inventory Control (to bring the -30,000 BACK UP to Zero)
        (v_voucher, 'adjustment', v_inventory_acc, v_balance, 0, CURRENT_DATE, 'Inventory Value Calibration (Rate Mismatch Reversal)', FALSE),
        
        -- Credit the Expense/COGS (to reverse the excess 30,000 cost booked earlier)
        (v_voucher, 'adjustment', v_expense_acc, 0, v_balance, CURRENT_DATE, 'Inventory Value Calibration (Rate Mismatch Reversal)', FALSE);
        
        RAISE NOTICE 'SUCCESS: Inventory adjustment of Rs 30,000 posted. Voucher %', v_voucher;
    ELSE
        RAISE EXCEPTION 'FAILED: Could not find required accounts.';
    END IF;

END $$;

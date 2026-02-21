-- ==============================================================================
-- FIX SCRIPT: CLEAR INVENTORY (CONTROL) RESIDUAL BALANCE
-- Purpose: Safely writes off the Rs 48,000 left in Inventory Control due to 
--          purchase/sale rate calculation mismatches.
-- Method:  Credits Inventory Control to bring it to 0, and Debits Cost of Goods Sold.
-- ==============================================================================

DO $$
DECLARE
    v_inventory_acc uuid;
    v_expense_acc uuid;
    v_voucher text := 'ADJ-' || TO_CHAR(NOW(), 'YYYYMMDD-HH24MI');
    v_balance numeric := 48000.00;
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

    -- SAFEFUARD: Only run if we found the accounts
    IF v_inventory_acc IS NOT NULL AND v_expense_acc IS NOT NULL THEN
        
        -- Insert Balancing Entry
        INSERT INTO ledger_entries 
        (voucher_no, voucher_type, account_id, debit_amount, credit_amount, posting_date, narration, is_reversed)
        VALUES 
        -- Debit the Expense/Capital (to absorb the loss in value)
        (v_voucher, 'adjustment', v_expense_acc, v_balance, 0, CURRENT_DATE, 'Inventory Value Calibration (Rate Mismatch Write-off)', FALSE),
        
        -- Credit Inventory Control (to finally bring the 48,000 down to Zero)
        (v_voucher, 'adjustment', v_inventory_acc, 0, v_balance, CURRENT_DATE, 'Inventory Value Calibration (Rate Mismatch Write-off)', FALSE);
        
        RAISE NOTICE 'SUCCESS: Inventory adjustment of Rs 48,000 posted. Voucher %', v_voucher;
    ELSE
        RAISE EXCEPTION 'FAILED: Could not find required accounts.';
    END IF;

END $$;

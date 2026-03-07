-- =================================================================================
-- ROLLBACK SCRIPT: REVERSE THE MANUAL 30,000 ADJUSTMENT VOUCHER
-- Purpose: If you decide the 30k adjustment was a mistake, this script creates
--          an exact opposing (reversing) journal entry to undo the financial impact.
-- =================================================================================

DO $$
DECLARE
    v_inventory_acc uuid;
    v_expense_acc uuid;
    v_voucher text := 'ADJ-REV-' || TO_CHAR(NOW(), 'YYYYMMDD-HH24MI');
    v_balance numeric := 30000.00;
BEGIN
    -- 1. Find Accounts
    SELECT id INTO v_inventory_acc FROM accounts 
    WHERE slug = 'inventory_control' OR name ILIKE '%Inventory%Control%' LIMIT 1;

    SELECT id INTO v_expense_acc FROM accounts 
    WHERE slug = 'cost_of_goods_sold' OR name ILIKE '%Cost of Goods%' LIMIT 1;
    
    IF v_expense_acc IS NULL THEN
        SELECT id INTO v_expense_acc FROM accounts 
        WHERE slug = 'owner_capital' OR name ILIKE '%Capital%' LIMIT 1;
    END IF;

    IF v_inventory_acc IS NOT NULL AND v_expense_acc IS NOT NULL THEN
        
        -- Insert Opposing Entry
        INSERT INTO ledger_entries 
        (voucher_no, voucher_type, account_id, debit_amount, credit_amount, posting_date, narration, is_reversed)
        VALUES 
        -- Revert Inventory: Credit it back to push it to negative 30,000
        (v_voucher, 'adjustment', v_inventory_acc, 0, v_balance, CURRENT_DATE, 'Reversal: Undoing Inventory Calibration', TRUE),
        
        -- Revert Expense: Debit it back to restore the high COGS
        (v_voucher, 'adjustment', v_expense_acc, v_balance, 0, CURRENT_DATE, 'Reversal: Undoing Inventory Calibration', TRUE);
        
        RAISE NOTICE 'SUCCESS: Reversing ADJ-REV voucher of Rs 30,000 posted.';
    ELSE
        RAISE EXCEPTION 'FAILED: Could not find required accounts.';
    END IF;

END $$;

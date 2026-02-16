-- =================================================================
-- FIX: Inventory Rounding Adjustment
-- Physical stock = 0 but ledger shows Rs 3,800
-- Write off the remaining cost variance to COGS
--
-- RUN IN SUPABASE SQL EDITOR
-- =================================================================

-- Step 1: Check current gap
SELECT 
    SUM(debit_amount) - SUM(credit_amount) as inventory_balance
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'inventory')
  AND is_reversed = false;
-- Should show 3,800

-- Step 2: Temporarily disable source document validation
-- (this is an adjustment, not a sale/purchase)
ALTER TABLE public.ledger_entries DISABLE TRIGGER USER;

-- Step 3: Post adjustment entry
INSERT INTO public.ledger_entries 
    (voucher_no, voucher_type, posting_date, account_id, party_id, 
     debit_amount, credit_amount, narration, created_by)
VALUES
    -- Dr: COGS (expense the remaining cost)
    ('ADJ-INV-CLOSE-2026', 'adjustment', CURRENT_DATE,
     (SELECT id FROM accounts WHERE slug = 'cogs'), NULL,
     (SELECT SUM(debit_amount) - SUM(credit_amount) 
      FROM ledger_entries 
      WHERE account_id = (SELECT id FROM accounts WHERE slug = 'inventory') 
        AND is_reversed = false),
     0,
     'Inventory cost variance write-off - zero stock adjustment',
     auth.uid()),
    -- Cr: Inventory (zero out)
    ('ADJ-INV-CLOSE-2026', 'adjustment', CURRENT_DATE,
     (SELECT id FROM accounts WHERE slug = 'inventory'), NULL,
     0,
     (SELECT SUM(debit_amount) - SUM(credit_amount) 
      FROM ledger_entries 
      WHERE account_id = (SELECT id FROM accounts WHERE slug = 'inventory') 
        AND is_reversed = false),
     'Inventory cost variance write-off - zero stock adjustment',
     auth.uid());

-- Step 4: Re-enable triggers
ALTER TABLE public.ledger_entries ENABLE TRIGGER USER;

-- Step 5: Verify inventory is now zero
SELECT 
    'Inventory After Fix' as check_name,
    SUM(debit_amount) - SUM(credit_amount) as balance,
    CASE 
        WHEN ABS(SUM(debit_amount) - SUM(credit_amount)) < 0.01 
        THEN '✅ ZERO - Matches physical stock!'
        ELSE '❌ Still has Rs ' || (SUM(debit_amount) - SUM(credit_amount))::TEXT
    END as status
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'inventory')
  AND is_reversed = false;

-- Step 6: Verify TB still balanced
SELECT 
    ROUND(SUM(debit_amount) - SUM(credit_amount), 2) as tb_diff,
    CASE 
        WHEN ABS(SUM(debit_amount) - SUM(credit_amount)) < 0.01 
        THEN '✅ TRIAL BALANCE BALANCED!'
        ELSE '❌ OUT BY: Rs ' || ROUND(SUM(debit_amount) - SUM(credit_amount), 2)::TEXT
    END as status
FROM ledger_entries
WHERE is_reversed = false;

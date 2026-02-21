-- ==============================================================================
-- TEST SCRIPT: AUDIT INVENTORY (CONTROL) BALANCE
-- Purpose: To investigate why Inventory (Control) is showing Rs 48,000 when stock is 0.
-- Safe to run: YES (Read-Only SELECT query)
-- Location to run: Supabase SQL Editor
-- ==============================================================================

-- STEP 1: VERIFY EXACT INVENTORY LEDGER BALANCE
SELECT 
    a.code,
    a.name,
    SUM(le.debit_amount) AS total_purchases_dr,
    SUM(le.credit_amount) AS total_cogs_cr,
    (SUM(le.debit_amount) - SUM(le.credit_amount)) AS net_inventory_value
FROM ledger_entries le
JOIN accounts a ON le.account_id = a.id
WHERE a.slug = 'inventory_control' OR a.name ILIKE '%Inventory%Control%'
GROUP BY a.code, a.name;

---------------------------------------------------------------------------------

-- STEP 2: FIND EXACT VOUCHERS CAUSING THE RESIDUAL BALANCE 
-- This will list all transactions affecting Inventory to see what is missing
SELECT 
    le.posting_date,
    le.voucher_no,
    le.voucher_type,
    le.debit_amount AS inventory_added_value_dr,
    le.credit_amount AS inventory_removed_value_cr,
    le.narration
FROM ledger_entries le
JOIN accounts a ON le.account_id = a.id
WHERE (a.slug = 'inventory_control' OR a.name ILIKE '%Inventory%Control%')
  -- Ignore fully reversed entries to clean up the view
  AND le.is_reversed = FALSE
ORDER BY le.posting_date ASC, le.created_at ASC;

---------------------------------------------------------------------------------

-- STEP 3: CHECK OVERALL STOCK VS VALUE DISCREPANCY
-- This shows physical fuel quantity against the financial ledger value
SELECT 
    f.name AS product_name,
    f.current_stock AS physical_litres_remaining,
    -- Get financial value from ledger 
    (SELECT COALESCE(SUM(debit_amount - credit_amount), 0) 
     FROM ledger_entries le 
     JOIN accounts a ON le.account_id = a.id 
     WHERE a.slug = 'inventory_control') AS total_financial_inventory_value
FROM fuel_types f;

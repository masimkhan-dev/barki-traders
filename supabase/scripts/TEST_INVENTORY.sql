-- =================================================================
-- TEST: Inventory / Stock Deep Inspection
-- User says actual stock is ZERO but system shows Rs 3,800
-- RUN IN SUPABASE SQL EDITOR
-- =================================================================

-- 1. Inventory Control Account - Ledger Summary
SELECT 
    'Inventory Control (1200)' as account,
    SUM(debit_amount) as total_purchased,
    SUM(credit_amount) as total_sold_cogs,
    SUM(debit_amount) - SUM(credit_amount) as remaining_value
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'inventory')
  AND is_reversed = false;

-- 2. Physical Stock from inventory table
SELECT 
    ft.name as fuel_type,
    i.quantity as current_qty,
    i.avg_cost,
    i.quantity * i.avg_cost as value
FROM inventory i
JOIN fuel_types ft ON ft.id = i.fuel_type_id
ORDER BY ft.name;

-- 3. Purchases vs Sales by fuel type
SELECT 
    ft.name as fuel_type,
    COALESCE(p.total_qty, 0) as qty_purchased,
    COALESCE(p.total_value, 0) as purchase_value,
    COALESCE(s.total_qty, 0) as qty_sold,
    COALESCE(s.total_value, 0) as sale_revenue,
    COALESCE(p.total_qty, 0) - COALESCE(s.total_qty, 0) as qty_remaining
FROM fuel_types ft
LEFT JOIN (
    SELECT fuel_type_id, SUM(quantity) as total_qty, SUM(total_amount) as total_value
    FROM purchases GROUP BY fuel_type_id
) p ON p.fuel_type_id = ft.id
LEFT JOIN (
    SELECT fuel_type_id, SUM(quantity) as total_qty, SUM(total_amount) as total_value
    FROM sales GROUP BY fuel_type_id
) s ON s.fuel_type_id = ft.id
ORDER BY ft.name;

-- 4. Last 20 inventory ledger entries (find the Rs 3,800 gap)
SELECT 
    le.posting_date,
    le.voucher_no,
    le.voucher_type,
    le.narration,
    le.debit_amount as stock_in,
    le.credit_amount as stock_out,
    le.is_reversed
FROM ledger_entries le
WHERE le.account_id = (SELECT id FROM accounts WHERE slug = 'inventory')
ORDER BY le.posting_date DESC, le.created_at DESC
LIMIT 20;

-- 5. COGS Check: Does COGS match what came out of inventory?
SELECT 
    'COGS (expense)' as source,
    SUM(debit_amount) as total
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'cogs')
  AND is_reversed = false

UNION ALL

SELECT 
    'Inventory Out (credit)' as source,
    SUM(credit_amount) as total
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'inventory')
  AND is_reversed = false;

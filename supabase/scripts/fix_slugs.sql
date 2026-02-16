-- FIX: Missing Account Slugs for V11 Triggers
-- This script ensures critical system accounts have the correct 'slug' identifier required by database triggers.

BEGIN;

-- 1. Inventory Account
UPDATE accounts 
SET slug = 'inventory' 
WHERE slug IS NULL 
  AND (name ILIKE '%Inventory%' OR code = '1000' OR account_type = 'asset');

-- 2. Accounts Payable (Suppliers)
UPDATE accounts 
SET slug = 'ap' 
WHERE slug IS NULL 
  AND (name ILIKE '%Payable%' OR name ILIKE '%Supplier%' OR code = '2000');

-- 3. Accounts Receivable (Customers)
UPDATE accounts 
SET slug = 'ar' 
WHERE slug IS NULL 
  AND (name ILIKE '%Receivable%' OR name ILIKE '%Customer%' OR code = '1010');

-- 4. Sales Revenue
UPDATE accounts 
SET slug = 'sales_revenue' 
WHERE slug IS NULL 
  AND (name ILIKE '%Sales%' OR name ILIKE '%Revenue%' OR code = '4000');

-- 5. Cost of Goods Sold (COGS)
UPDATE accounts 
SET slug = 'cogs' 
WHERE slug IS NULL 
  AND (name ILIKE '%Cost%' OR name ILIKE '%COGS%' OR code = '5000');

-- 6. Cash Account
UPDATE accounts 
SET slug = 'cash' 
WHERE slug IS NULL 
  AND (name ILIKE '%Cash%' OR code = '1001');

COMMIT;

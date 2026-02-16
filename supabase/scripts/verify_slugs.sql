-- DIAGNOSTIC SCRIPT: Verify if System Accounts have Slugs
-- If the 'slug' column is NULL for these accounts, the Purchase Trigger WILL FAIL.

SELECT 
    id, 
    name, 
    code, 
    account_type,
    slug,
    CASE 
        WHEN slug IS NULL THEN '❌ CRITICAL: MISSING SLUG (Will Cause Error)' 
        ELSE '✅ OK' 
    END as status
FROM accounts 
WHERE 
    name ILIKE '%Inventory%' 
    OR name ILIKE '%Payable%'
    OR name ILIKE '%Receivable%'
    OR name ILIKE '%Sales%'
    OR name ILIKE '%Cost of Goods%'
    OR name ILIKE '%Cash%'
ORDER BY code;

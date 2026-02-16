-- DIAGNOSTIC SCRIPT: CHECK EQUITY & ASSET FUNCTIONS
-- Purpose: Verify if the functions exist and match the expected parameters.

-- 1. Check if get_owner_capital_report exists and what its parameters are
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    t.typname as return_type
FROM pg_proc p
JOIN pg_type t ON p.prorettype = t.oid
WHERE p.proname = 'get_owner_capital_report';

-- 2. Check if get_fixed_assets_report exists
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    t.typname as return_type
FROM pg_proc p
JOIN pg_type t ON p.prorettype = t.oid
WHERE p.proname = 'get_fixed_assets_report';

-- 3. Check for specific accounts that these functions rely on
-- Capital Accounts
SELECT id, code, name, account_type, slug 
FROM public.accounts 
WHERE account_type = 'equity' 
   OR name ILIKE '%Capital%' 
   OR slug ILIKE '%capital%';

-- Fixed Asset Accounts
SELECT id, code, name, account_type, sub_category 
FROM public.accounts 
WHERE account_type = 'asset' 
   AND (sub_category ILIKE '%Fixed%' OR name ILIKE '%Furniture%' OR name ILIKE '%Building%');

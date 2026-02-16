
-- DIAGNOSE ASSET VISIBILITY
-- Purpose: See why 'laptop' is not showing in get_fixed_assets_report logic.

SELECT 
    id, 
    name, 
    sub_category, 
    account_type, 
    slug,
    -- Check if it matches the CURRENT buggy filter:
    (
        sub_category ILIKE '%Fixed%' OR 
        slug ILIKE '%fixed-asset%' OR 
        name ILIKE '%Furniture%' OR 
        name ILIKE '%Building%' OR 
        name ILIKE '%Vehicle%'
    ) as matches_current_filter
FROM accounts
WHERE name ILIKE '%laptop%';

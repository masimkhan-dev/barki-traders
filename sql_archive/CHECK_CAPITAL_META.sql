-- CHECK CAPITAL ACCOUNT DETAILS & LEDGER DROPDOWN VISIBILITY
-- Purpose: Find out why Proprietor Capital (3010) is missing from dropdowns and verify report logic.

SELECT 
    id, 
    name, 
    code, 
    account_type, 
    slug, 
    is_active, 
    is_system,
    COALESCE(sub_category, 'No Sub-Category') as sub_category
FROM accounts 
WHERE code = '3010' OR slug IN ('capital', 'owner-capital');

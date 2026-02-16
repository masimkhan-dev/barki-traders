
-- CHECK ASSET SUB-CATEGORIES
SELECT DISTINCT sub_category, account_type 
FROM accounts 
WHERE account_type = 'asset';

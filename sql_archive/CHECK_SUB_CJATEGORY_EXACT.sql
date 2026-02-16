
-- CHECK EXACT SUB-CATEGORY VALUE
SELECT 
    name, 
    sub_category, 
    ascii(substring(sub_category, 1, 1)) as first_char_ascii,
    length(sub_category) as len
FROM accounts 
WHERE name ILIKE '%laptop%';

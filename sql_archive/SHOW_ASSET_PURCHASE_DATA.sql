
-- SHOW DATA IN TABLE FORMAT
-- 1. The New Account Created
SELECT id, code, name, account_type, sub_category, created_at 
FROM accounts 
WHERE name ILIKE '%solar panel%' OR sub_category = 'Machinery'
ORDER BY created_at DESC;

-- 2. The Full Ledger Transaction (Double Entry)
-- We find the voucher number associated with the asset and show all legs of it.
SELECT 
    le.voucher_no,
    le.posting_date,
    a.name as account_name,
    a.code as account_code,
    le.debit_amount,
    le.credit_amount,
    le.narration
FROM ledger_entries le
JOIN accounts a ON le.account_id = a.id
WHERE le.voucher_no IN (
    SELECT voucher_no 
    FROM ledger_entries le2 
    JOIN accounts a2 ON le2.account_id = a2.id 
    WHERE a2.name ILIKE '%solar panel%'
)
ORDER BY le.voucher_no, le.created_at;

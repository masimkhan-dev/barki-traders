
-- SHOW DATA FOR LAPTOP PURCHASE
-- 1. The Full Ledger Transaction
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
    -- Find the voucher associated with the 'laptop' purchase
    SELECT le2.voucher_no 
    FROM ledger_entries le2 
    JOIN accounts a2 ON le2.account_id = a2.id 
    WHERE a2.name ILIKE '%laptop%'
)
ORDER BY le.voucher_no, le.credit_amount DESC; -- Credit usually listed last in double entry view

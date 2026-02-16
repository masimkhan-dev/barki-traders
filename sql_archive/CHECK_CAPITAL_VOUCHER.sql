
-- CHECK CAPITAL VOUCHER ENTRIES
-- Purpose: See ALL ledger entries for the Capital voucher to identify duplicates/errors.

SELECT 
    le.id,
    le.voucher_no,
    le.posting_date,
    a.name as account_name,
    a.slug,
    le.debit_amount,
    le.credit_amount,
    le.narration
FROM ledger_entries le
JOIN accounts a ON le.account_id = a.id
WHERE le.voucher_no LIKE 'CAP-%'
ORDER BY le.voucher_no, le.created_at;

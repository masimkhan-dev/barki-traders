
-- FIND ALL 50 LAKH ENTRIES
-- Purpose: Identify all ledger entries with amounts close to Rs 5,000,000 to find the pollution source.

SELECT 
    le.voucher_no,
    le.posting_date,
    a.name as account_name,
    a.slug,
    le.debit_amount,
    le.credit_amount,
    le.narration,
    le.created_at
FROM ledger_entries le
JOIN accounts a ON le.account_id = a.id
WHERE le.debit_amount >= 4900000 OR le.credit_amount >= 4900000
ORDER BY le.created_at;

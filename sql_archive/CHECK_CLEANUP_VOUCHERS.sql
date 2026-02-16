-- DIAGNOSE TRIAL BALANCE MISMATCH
-- Purpose: Check all vouchers for the cleanup to see if they're balanced

SELECT 
    voucher_no,
    posting_date,
    SUM(debit_amount) as total_debit,
    SUM(credit_amount) as total_credit,
    SUM(debit_amount) - SUM(credit_amount) as difference
FROM ledger_entries
WHERE voucher_no LIKE 'ZERO-ARCP-%' OR voucher_no LIKE 'ADJ-OBE-%'
  AND (is_reversed IS NULL OR is_reversed = false)
GROUP BY voucher_no, posting_date
ORDER BY posting_date;

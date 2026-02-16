-- FIND UNBALANCED VOUCHERS
-- Purpose: Identify any vouchers where Debit != Credit

SELECT 
    voucher_no,
    posting_date,
    SUM(debit_amount) as total_debit,
    SUM(credit_amount) as total_credit,
    SUM(debit_amount) - SUM(credit_amount) as difference
FROM ledger_entries
WHERE (is_reversed IS NULL OR is_reversed = false)
GROUP BY voucher_no, posting_date
HAVING SUM(debit_amount) != SUM(credit_amount)
ORDER BY ABS(SUM(debit_amount) - SUM(credit_amount)) DESC;

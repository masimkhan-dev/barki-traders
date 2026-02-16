
-- DIAGNOSE BALANCE SHEET INFLATION
-- Purpose: Find out which account/entry is causing the 50 Lakh+ Receivable/Payable spike.

SELECT 
    a.name as account_name,
    a.account_type,
    a.slug,
    SUM(le.debit_amount - le.credit_amount) as balance
FROM accounts a
JOIN ledger_entries le ON a.id = le.account_id
WHERE (le.is_reversed IS NULL OR le.is_reversed = false)
GROUP BY a.name, a.account_type, a.slug
HAVING ABS(SUM(le.debit_amount - le.credit_amount)) > 1000000; -- Look for balances over 10 Lakh

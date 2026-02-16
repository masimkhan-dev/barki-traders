-- CHECK FOR MISSING LIABILITIES
-- Purpose: See if there are liability accounts not showing up in Balance Sheet.

SELECT 
    a.name,
    a.slug,
    a.account_type,
    SUM(le.debit_amount - le.credit_amount) as balance
FROM accounts a
LEFT JOIN ledger_entries le ON a.id = le.account_id AND le.posting_date <= '2026-02-05'
WHERE a.account_type = 'liability'
  AND (le.is_reversed IS NULL OR le.is_reversed = false)
GROUP BY a.id, a.name, a.slug, a.account_type
ORDER BY balance;

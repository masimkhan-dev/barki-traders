-- FIND THE MISSING Rs 120,980
-- Purpose: Identify all equity accounts and their balances

SELECT 
    a.name,
    a.slug,
    a.code,
    COALESCE(SUM(le.credit_amount - le.debit_amount), 0) as balance
FROM accounts a
LEFT JOIN ledger_entries le ON a.id = le.account_id AND le.posting_date <= '2026-02-06'
WHERE a.account_type = 'equity'
  AND (le.is_reversed IS NULL OR le.is_reversed = false)
GROUP BY a.id, a.name, a.slug, a.code
ORDER BY balance DESC;

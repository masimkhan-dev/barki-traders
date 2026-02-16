-- VERIFY AR/AP ARE ZEROED
-- Purpose: Check if cleanup scripts successfully zeroed AR/AP control accounts

SELECT 
    'AR Balance' as account,
    SUM(debit_amount - credit_amount) as balance
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'ar')
  AND (is_reversed IS NULL OR is_reversed = false)

UNION ALL

SELECT 
    'AP Balance' as account,
    SUM(debit_amount - credit_amount) as balance
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'ap')
  AND (is_reversed IS NULL OR is_reversed = false);

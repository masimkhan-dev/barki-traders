
-- CHECK AR ACCOUNT ENTRIES
-- Purpose: See what's causing the Rs 50 Lakh balance in Accounts Receivable.

SELECT 
    le.voucher_no,
    le.posting_date,
    le.debit_amount,
    le.credit_amount,
    le.narration,
    le.party_id,
    p.name as party_name
FROM ledger_entries le
LEFT JOIN parties p ON le.party_id = p.id
WHERE le.account_id = (SELECT id FROM accounts WHERE slug = 'ar')
  AND (le.is_reversed IS NULL OR le.is_reversed = false)
ORDER BY le.posting_date, le.created_at;

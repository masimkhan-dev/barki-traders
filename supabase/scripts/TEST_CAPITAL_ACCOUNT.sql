-- =================================================================
-- TEST: Owner's Capital Account Deep Inspection
-- Run in Supabase SQL Editor
-- =================================================================

-- 1. Capital Account Info
SELECT id, name, slug, account_type, code
FROM accounts
WHERE slug = 'capital';

-- 2. ALL ledger entries hitting Capital account
SELECT 
    le.posting_date,
    le.voucher_no,
    le.voucher_type,
    le.narration,
    le.debit_amount,
    le.credit_amount,
    le.is_reversed,
    COALESCE(p.name, '—') as party_name
FROM ledger_entries le
LEFT JOIN parties p ON le.party_id = p.id
WHERE le.account_id = (SELECT id FROM accounts WHERE slug = 'capital')
ORDER BY le.posting_date, le.created_at;

-- 3. Capital Balance Summary
SELECT
    SUM(debit_amount) as total_debit,
    SUM(credit_amount) as total_credit,
    SUM(credit_amount) - SUM(debit_amount) as net_balance,
    CASE 
        WHEN SUM(credit_amount) - SUM(debit_amount) >= 0 
        THEN 'Cr (Positive Equity) ✅'
        ELSE 'Dr (Negative Equity) ⚠️'
    END as status
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'capital')
  AND is_reversed = false;

-- 4. Breakdown by voucher_type
SELECT
    voucher_type,
    COUNT(*) as entry_count,
    SUM(debit_amount) as total_dr,
    SUM(credit_amount) as total_cr,
    SUM(credit_amount) - SUM(debit_amount) as net_effect
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'capital')
  AND is_reversed = false
GROUP BY voucher_type
ORDER BY ABS(SUM(credit_amount) - SUM(debit_amount)) DESC;

-- 5. What SHOULD Capital look like?
-- Opening balance contras vs actual owner equity
SELECT
    'Opening Balance Contras (should move to Retained Earnings)' as description,
    SUM(debit_amount) as dr,
    SUM(credit_amount) as cr
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'capital')
  AND voucher_type = 'opening'
  AND is_reversed = false

UNION ALL

SELECT
    'Actual Owner Equity (real capital)' as description,
    SUM(debit_amount) as dr,
    SUM(credit_amount) as cr
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'capital')
  AND voucher_type != 'opening'
  AND is_reversed = false;

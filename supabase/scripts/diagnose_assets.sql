-- ============================================================================
-- AUDIT & DIAGNOSE: FIND THE NEGATIVE ASSET
-- ============================================================================

-- 1. GL ACCOUNT BALANCES (Where is the negative number?)
SELECT 
    a.code, 
    a.name, 
    a.account_type, 
    ROUND(SUM(le.debit_amount - le.credit_amount), 2) as balance
FROM accounts a
JOIN ledger_entries le ON le.account_id = a.id
WHERE COALESCE(le.is_reversed, false) = false
GROUP BY a.code, a.name, a.account_type
ORDER BY balance ASC; -- Show negative balances first

-- 2. PARTY BALANCES (Is a customer massively negative?)
SELECT 
    p.name, 
    p.type, 
    recalculate_party_balance(p.id) as balance
FROM parties p
WHERE p.is_active = true
ORDER BY balance ASC
LIMIT 10;

-- 3. TOTAL ASSETS CALCULATION BREAKDOWN
SELECT 
    'GL_ASSETS_SUM' as component,
    COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as value
FROM accounts a
JOIN ledger_entries le ON le.account_id = a.id
WHERE a.account_type = 'asset' 
  AND COALESCE(le.is_reversed, false) = false

UNION ALL

SELECT 
    'PARTY_RECEIVABLES_SUM',
    SUM(CASE WHEN recalculate_party_balance(id) > 0 THEN recalculate_party_balance(id) ELSE 0 END)
FROM parties;

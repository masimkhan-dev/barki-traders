-- ============================================================================
-- QUICK APPLY: Ledger Balance Fix Migration
-- ============================================================================
-- This script applies the 20260125170000_fix_ledger_balance_calculations.sql
-- migration and runs validation checks.
--
-- USAGE:
-- 1. Copy this entire script
-- 2. Go to Supabase Dashboard → SQL Editor
-- 3. Paste and run
-- 4. Review the validation results at the bottom
-- ============================================================================

\echo '==================================================================='
\echo 'STEP 1: Applying Ledger Balance Fix Migration'
\echo '==================================================================='
\ir ../migrations/20260125170000_fix_ledger_balance_calculations.sql

\echo ''
\echo '==================================================================='
\echo 'STEP 2: Running Audit Checks'
\echo '==================================================================='
SELECT 
    '❌ ISSUES FOUND' as status,
    issue_type,
    voucher_no,
    party_name,
    description,
    severity
FROM audit_ledger_integrity()
UNION ALL
SELECT 
    '✅ NO ISSUES' as status,
    NULL, NULL, NULL, NULL, NULL
WHERE NOT EXISTS (SELECT 1 FROM audit_ledger_integrity())
ORDER BY status DESC;

\echo ''
\echo '==================================================================='
\echo 'STEP 3: Party Balance Summary'
\echo '==================================================================='
SELECT 
    p.name as party_name,
    p.party_type,
    recalculate_party_balance(p.id) as balance,
    CASE 
        WHEN recalculate_party_balance(p.id) >= 0 THEN 'Dr (Receivable)'
        ELSE 'Cr (Payable)'
    END as balance_type,
    ABS(recalculate_party_balance(p.id)) as amount
FROM parties p
WHERE p.is_active = true
ORDER BY ABS(recalculate_party_balance(p.id)) DESC
LIMIT 20;

\echo ''
\echo '==================================================================='
\echo 'STEP 4: Voucher Balance Check (Today)'
\echo '==================================================================='
SELECT 
    voucher_no,
    voucher_type,
    ROUND(SUM(debit_amount)::NUMERIC, 2) as total_debit,
    ROUND(SUM(credit_amount)::NUMERIC, 2) as total_credit,
    ROUND(SUM(debit_amount) - SUM(credit_amount)::NUMERIC, 2) as difference
FROM ledger_entries
WHERE posting_date >= CURRENT_DATE - INTERVAL '7 days'
  AND is_reversed = false
GROUP BY voucher_no, voucher_type
HAVING ROUND(SUM(debit_amount)::NUMERIC, 2) != ROUND(SUM(credit_amount)::NUMERIC, 2)
ORDER BY ABS(SUM(debit_amount) - SUM(credit_amount)) DESC;

\echo ''
\echo '==================================================================='
\echo 'STEP 5: Ledger Entry Statistics'
\echo '==================================================================='
SELECT 
    'Total Active Entries' as metric,
    COUNT(*)::TEXT as value
FROM ledger_entries
WHERE is_reversed = false
UNION ALL
SELECT 
    'Entries with NULL amounts (should be 0)',
    COUNT(*)::TEXT
FROM ledger_entries
WHERE debit_amount IS NULL OR credit_amount IS NULL
UNION ALL
SELECT 
    'Total Suppliers Balance (Cr)',
    ABS(SUM(recalculate_party_balance(p.id)))::TEXT
FROM parties p
WHERE p.party_type = 'supplier' AND recalculate_party_balance(p.id) < 0
UNION ALL
SELECT 
    'Total Customers Balance (Dr)',
    SUM(recalculate_party_balance(p.id))::TEXT
FROM parties p
WHERE p.party_type = 'customer' AND recalculate_party_balance(p.id) > 0;

\echo ''
\echo '==================================================================='
\echo '✅ Migration Complete!'
\echo '==================================================================='
\echo 'Check the results above.'
\echo 'If "NO ISSUES" appears in STEP 2, the migration was successful.'
\echo ''
\echo 'To test a specific party statement, run:'
\echo 'SELECT * FROM get_party_statement(party_id, start_date, end_date);'
\echo '==================================================================='

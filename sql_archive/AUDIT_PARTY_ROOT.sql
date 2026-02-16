-- FINAL AUDIT: ROOT CAUSE OF PARTY OPENING & RS 1,000 GAP
-- Purpose: Find exactly where the parties' 121k came from and why 1,000 is still missing.

-- 1. Check Party Table Opening Balances
SELECT 
    'Parties Table' as source,
    name, 
    type, 
    opening_balance 
FROM public.parties 
WHERE opening_balance != 0;

-- 2. Check Ledger for Opening Vouchers (excluding the 5M ones)
SELECT 
    'Ledger' as source,
    a.name as account,
    le.voucher_no,
    le.debit_amount,
    le.credit_amount,
    le.narration
FROM public.ledger_entries le
JOIN public.accounts a ON le.account_id = a.id
WHERE (le.voucher_type = 'opening_balance' OR le.narration ILIKE '%opening%')
  AND ABS(le.debit_amount - le.credit_amount) < 1000000; -- Look for normal opening balances

-- 3. Check Exact Remaining Balances of AR/AP to find the 1,000
SELECT 
    a.name, 
    a.code,
    SUM(le.debit_amount - le.credit_amount) as total_balance
FROM public.accounts a
JOIN public.ledger_entries le ON a.id = le.account_id
WHERE a.code IN ('1100', '2100', '1010')
GROUP BY a.id, a.name, a.code;
 
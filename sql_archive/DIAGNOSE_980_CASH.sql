-- FIND THE 980 CASH MISMATCH
-- 1. Get the account ID for Cash on Hand
SELECT id, name, code FROM public.accounts WHERE code = '1010';

-- 2. Find any entries with exactly 980
SELECT voucher_no, posting_date, debit_amount, credit_amount, narration, created_at
FROM public.ledger_entries
WHERE (debit_amount = 980 OR credit_amount = 980 OR debit_amount = 5010980 OR credit_amount = 5010980)
  AND (is_reversed IS NULL OR is_reversed = false);

-- 3. Check for the 980 difference between reports
-- Let's see the raw sum in ledger for 1010
SELECT 
    'Ledger Raw Sum' as source,
    SUM(debit_amount - credit_amount) as balance
FROM public.ledger_entries le
JOIN public.accounts a ON le.account_id = a.id
WHERE a.code = '1010' AND (le.is_reversed IS NULL OR le.is_reversed = false);

-- 4. Check if there's an entry that was supposed to be 5,010,000 but became 5,010,980
SELECT * FROM public.ledger_entries WHERE (debit_amount > 5000000 OR credit_amount > 5000000);

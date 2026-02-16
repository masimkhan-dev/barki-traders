-- FINDING THE 980 PKR SOURCE
-- We search for any voucher or sum of vouchers that equals 980 specifically in Cash
SELECT 
    voucher_no, 
    narration, 
    debit_amount, 
    credit_amount, 
    posting_date
FROM public.ledger_entries 
WHERE account_id = (SELECT id FROM accounts WHERE code = '1010' LIMIT 1)
  AND (debit_amount = 980 OR credit_amount = 980 OR (debit_amount - credit_amount) = 980)
  AND (is_reversed IS NULL OR is_reversed = false);

-- ALSO CHECK OPENING BALANCE VOUCHERS
SELECT 
    voucher_no, 
    narration, 
    debit_amount, 
    credit_amount
FROM public.ledger_entries 
WHERE voucher_type = 'opening_balance' 
  AND account_id = (SELECT id FROM accounts WHERE code = '1010' LIMIT 1);

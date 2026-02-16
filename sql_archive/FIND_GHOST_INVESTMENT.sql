-- FIND INVESTMENTS
SELECT id, name, code, account_type FROM public.accounts WHERE name ILIKE '%Investment%';

-- FIND LEDGER ENTRIES FOR UNBALANCED RECORDS
SELECT le.voucher_no, le.narration, a.name, le.debit_amount, le.credit_amount
FROM public.ledger_entries le
LEFT JOIN public.accounts a ON le.account_id = a.id
WHERE a.name ILIKE '%Investment%' OR le.narration ILIKE '%Investment%';

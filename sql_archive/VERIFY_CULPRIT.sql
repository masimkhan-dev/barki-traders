-- SEARCH FOR THE SPECIFIC VOUCHER AND ITS REVERSAL
SELECT 
    le.voucher_no,
    le.posting_date,
    le.debit_amount,
    le.credit_amount,
    le.is_reversed,
    le.narration
FROM public.ledger_entries le
WHERE le.voucher_no LIKE '%EXP-20260201-0010%'
   OR le.narration LIKE '%EXP-20260201-0010%';

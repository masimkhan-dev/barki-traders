-- =================================================================
-- AUDIT SCRIPT: CHECKING EXPENSES AND REVERSALS
-- =================================================================

SELECT 
    le.id, 
    le.voucher_no, 
    a.name as account_name, 
    le.debit_amount, 
    le.credit_amount, 
    le.is_reversed,
    le.reversal_of_voucher,
    le.posting_date,
    le.description
FROM public.ledger_entries le
JOIN public.accounts a ON a.id = le.account_id
WHERE a.account_type = 'expense'
ORDER BY le.posting_date DESC, le.id DESC
LIMIT 50;

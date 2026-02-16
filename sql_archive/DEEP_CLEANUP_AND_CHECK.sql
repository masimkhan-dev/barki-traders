-- STEP 1: DEEP CLEANUP OF CLOSING ENTRIES
-- Purpose: Ensure NO closing entries exist before we try again.

DELETE FROM public.ledger_entries 
WHERE voucher_no LIKE 'CL-%' 
   OR narration ILIKE '%NIL Adjustment%'
   OR narration ILIKE '%Profit Transfer%';

-- STEP 2: CHECK CURRENT P&L STATUS (TO SEE IF PROFIT IS DETECTED)
SELECT 
    a.account_type,
    SUM(CASE WHEN a.account_type = 'income' THEN (le.credit_amount - le.debit_amount) ELSE (le.debit_amount - le.credit_amount) END) as period_balance
FROM public.ledger_entries le 
JOIN public.accounts a ON le.account_id = a.id
WHERE le.posting_date BETWEEN '2026-02-01' AND '2026-02-28'
  AND a.account_type IN ('income', 'expense')
  AND (le.is_reversed IS NULL OR le.is_reversed = false)
GROUP BY a.account_type;

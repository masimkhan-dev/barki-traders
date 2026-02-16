-- DIAGNOSTIC SCRIPT: FIND THE 1,000 PKR MISMATCH
-- Purpose: Identify exactly which transaction is causing the P&L vs Balance Sheet drift.

-- 1. Check for any REVERSED entries (Amount 1000) that might be ignored by P&L but counted by Balance Sheet
SELECT 
    le.voucher_no,
    le.voucher_type,
    le.posting_date,
    a.name as account_name,
    a.account_type,
    le.debit_amount,
    le.credit_amount,
    le.is_reversed,
    le.narration
FROM public.ledger_entries le
JOIN public.accounts a ON le.account_id = a.id
WHERE a.account_type IN ('income', 'expense')
  AND (le.debit_amount = 1000 OR le.credit_amount = 1000)
ORDER BY le.posting_date DESC;


-- 2. Compare Total Profit with and without the 'is_reversed' filter
WITH profit_comparison AS (
    -- AS PER P&L (Filters reversals and date)
    SELECT 
        'PNL_LOGIC' as method,
        SUM(le.credit_amount - le.debit_amount) as net_profit
    FROM public.ledger_entries le
    JOIN public.accounts a ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND le.posting_date BETWEEN '2025-01-01' AND '2026-05-02'
    
    UNION ALL
    
    -- AS PER BALANCE SHEET (Currently ignores reversals)
    SELECT 
        'BS_LOGIC_CURRENT' as method,
        SUM(le.credit_amount - le.debit_amount) as net_profit
    FROM public.ledger_entries le
    JOIN public.accounts a ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date <= '2026-05-02'
)
SELECT * FROM profit_comparison;


-- 3. Check for entries OUTSIDE the P&L range (Before 2025-01-01)
SELECT 
    le.voucher_no,
    le.posting_date,
    a.name,
    le.debit_amount,
    le.credit_amount
FROM public.ledger_entries le
JOIN public.accounts a ON le.account_id = a.id
WHERE a.account_type IN ('income', 'expense')
  AND le.posting_date < '2025-01-01';

-- =================================================================
-- MASTER ACCOUNTING FIX: P&L DOUBLE COUNTING & DAILY BOOK ERROR
-- Purpose: 
-- 1. Data Repair: Ensure 'Fuel Purchase Cost' is an ASSET, not an EXPENSE.
-- 2. Schema Fix: Add 'reconciliation_status' to fix Daily Book 400 error.
-- 3. Robust P&L: Redefine get_profit_loss with strict type partitioning.
-- =================================================================

BEGIN;

-- 1. FIX DATA TYPES (The Root Cause)
-- Fuel Purchase Cost should be an Asset (Inventory), not an Expense.
-- If it's an expense, P&L subtracts it. If it's an Asset, it stays in Balance Sheet.
UPDATE public.accounts 
SET account_type = 'asset', slug = 'inventory' 
WHERE (name ILIKE '%Fuel Purchase Cost%' OR name ILIKE '%Inventory%')
  AND account_type = 'expense';

-- Ensure Cost of Goods Sold is correctly tagged as an Expense.
UPDATE public.accounts 
SET account_type = 'expense', slug = 'cogs' 
WHERE (name ILIKE '%Cost of Goods Sold%' OR slug = 'cogs')
  AND account_type != 'expense';

-- 2. FIX TABLE STRUCTURE (For Roznamcha / Daily Book Error)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'ledger_entries' AND column_name = 'reconciliation_status'
    ) THEN
        ALTER TABLE public.ledger_entries ADD COLUMN reconciliation_status BOOLEAN DEFAULT false;
        ALTER TABLE public.ledger_entries ADD COLUMN reconciled_at TIMESTAMPTZ;
    END IF;
END $$;

-- 3. FINAL ROBUST P&L FUNCTION
DROP FUNCTION IF EXISTS public.get_profit_loss(DATE, DATE) CASCADE;

CREATE OR REPLACE FUNCTION public.get_profit_loss(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    section TEXT,
    account_name TEXT,
    amount NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    -- A. INCOME (Sales Revenue ONLY)
    SELECT 
        'Income'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'income' AND a.is_active = true
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- B. DIRECT COSTS (Cost of Goods Sold ONLY)
    -- Must be type 'expense' and identified as COGS.
    SELECT 
        'Direct Costs'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense' 
      AND (a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%Cost of Goods Sold%')
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- C. OPERATING EXPENSES (Other Expenses ONLY, Excluding COGS)
    SELECT 
        'Expenses'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense' AND a.is_active = true
      AND COALESCE(a.slug, '') <> 'cogs'
      AND a.code <> '4100'
      AND a.name NOT ILIKE '%Cost of Goods Sold%'
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0;
END;
$$;

-- 4. PAYMENTS REPORT RPC (Captures all money movement)
DROP FUNCTION IF EXISTS public.get_payments_report(DATE, DATE) CASCADE;
CREATE OR REPLACE FUNCTION public.get_payments_report(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    posting_date DATE,
    voucher_no TEXT,
    voucher_type TEXT,
    party_name TEXT,
    account_name TEXT,
    debit_amount NUMERIC,
    credit_amount NUMERIC,
    narration TEXT
) LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT 
        le.posting_date,
        le.voucher_no,
        le.voucher_type,
        p.name as party_name,
        a.name as account_name,
        le.debit_amount,
        le.credit_amount,
        le.narration
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    LEFT JOIN parties p ON le.party_id = p.id
    WHERE le.voucher_type IN ('receipt', 'payment', 'transfer', 'munshi_voucher', 'journal')
      AND le.posting_date BETWEEN p_start_date AND p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      -- Filter to show only the "Interesting" side (Party side or non-cash side)
      AND (
          le.party_id IS NOT NULL 
          OR a.slug NOT IN ('cash', 'bank') 
          OR a.code NOT IN ('1000', '1010')
      )
    ORDER BY le.posting_date DESC, le.created_at DESC;
END;
$$;

COMMIT;
        
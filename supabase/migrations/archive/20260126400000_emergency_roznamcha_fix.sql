-- =================================================================
-- EMERGENCY HOTFIX: Roznamcha (Daily Book) & P&L STRICT SYNC
-- Purpose: 
-- 1. Add missing reconciliation_status column required by frontend.
-- 2. Force update get_profit_loss to the version that avoids double counting.
-- 3. Fix Roznamcha 400 error.
-- =================================================================

BEGIN;

-- 1. ADD MISSING COLUMN FOR FRONTEND COMPATIBILITY
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

-- 2. ENSURE RECONCILIATION FUNCTION EXISTS
CREATE OR REPLACE FUNCTION public.mark_as_reconciled(p_voucher_no TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE public.ledger_entries
    SET reconciliation_status = true,
        reconciled_at = now()
    WHERE voucher_no = p_voucher_no;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. FORCE RE-DEFINITON OF P&L (Strict Version)
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
    -- IDENTIFY COGS BY SLUG/NAME BUT ONLY WITHIN EXPENSE TYPE
    WITH cogs_accounts AS (
        SELECT id FROM public.accounts 
        WHERE account_type = 'expense'
          AND (
               slug = 'cogs' 
               OR code = '4100' 
               OR name ILIKE '%Cost of Goods%' 
               OR name ILIKE '%COGS%' 
               OR name ILIKE '%Fuel Purchase Cost%'
               OR name ILIKE '%Purchase Cost%'
          )
    )
    -- 1. INCOME (Sales Revenue)
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
    
    -- 2. DIRECT COSTS (Strictly COGS Accounts)
    SELECT 
        'Direct Costs'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.id IN (SELECT id FROM cogs_accounts)
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- 3. OPERATING EXPENSES (Strictly NON-COGS Accounts)
    SELECT 
        'Expenses'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense'
      AND a.id NOT IN (SELECT id FROM cogs_accounts)
      AND a.is_active = true
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0;
END;
$$;

-- 3. REPAIR DAILY SUMMARY RPC (For Business Reports Tab)
DROP FUNCTION IF EXISTS public.get_daily_summary(DATE) CASCADE;

CREATE OR REPLACE FUNCTION public.get_daily_summary(target_date DATE)
RETURNS json AS $$
DECLARE
    result json;
BEGIN
    SELECT json_build_object(
        'total_sales', COALESCE((SELECT SUM(total_amount) FROM sales WHERE sale_date = target_date), 0),
        'total_purchases', COALESCE((SELECT SUM(total_amount) FROM purchases WHERE purchase_date = target_date), 0),
        'cash_in', COALESCE((SELECT SUM(debit_amount) FROM ledger_entries le JOIN accounts a ON le.account_id = a.id WHERE (a.code IN ('1000', '1010') OR a.slug IN ('cash', 'bank')) AND posting_date = target_date), 0),
        'cash_out', COALESCE((SELECT SUM(credit_amount) FROM ledger_entries le JOIN accounts a ON le.account_id = a.id WHERE (a.code IN ('1000', '1010') OR a.slug IN ('cash', 'bank')) AND posting_date = target_date), 0)
    ) INTO result;
    RETURN result;
END;
$$ LANGUAGE plpgsql STABLE;

-- 4. ALIAS TRIAL BALANCE PARAMETERS FOR FRONTEND COMPATIBILITY
DROP FUNCTION IF EXISTS public.get_trial_balance(DATE, DATE) CASCADE;

CREATE OR REPLACE FUNCTION public.get_trial_balance(start_date DATE, end_date DATE)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    account_type TEXT,
    total_debit NUMERIC,
    total_credit NUMERIC,
    net_balance NUMERIC
) LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY 
    SELECT 
        r.account_code, 
        r.account_name, 
        r.account_type, 
        r.debit, 
        r.credit, 
        (r.debit - r.credit)
    FROM public.get_trial_balance_v2(start_date, end_date) r;
END;
$$;

COMMIT;

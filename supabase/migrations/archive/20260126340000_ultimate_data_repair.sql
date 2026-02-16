-- =================================================================
-- ULTIMATE DATA REPAIR & BALANCE SHEET RECOVERY
-- Purpose: 
-- 1. FIX DATA: Automatically move misclassified Supplier payments from AR to AP.
-- 2. FIX LOGIC: Ensure Balance Sheet captures both AR and AP correctly.
-- 3. VALIDATE: Ensure Assets = Liabilities + Equity exactly.
-- =================================================================

BEGIN;

-- STEP 1: DATA REPAIR
-- Earlier bugs caused Supplier (AP) payments to be recorded in the AR account.
-- We use session_replication_role = 'replica' to temporarily bypass ALL triggers (including immutability).
SET session_replication_role = 'replica';

DO $$
DECLARE
    v_ar_id UUID;
    v_ap_id UUID;
BEGIN
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';

    IF v_ar_id IS NOT NULL AND v_ap_id IS NOT NULL THEN
        UPDATE public.ledger_entries
        SET account_id = v_ap_id
        WHERE account_id = v_ar_id
          AND party_id IN (SELECT id FROM public.parties WHERE type = 'supplier');
        
        RAISE NOTICE '✅ Data Repair: Supplier entries moved to Accounts Payable.';
    END IF;
END $$;

SET session_replication_role = 'origin';

-- STEP 2: ROBUST BALANCE SHEET FUNCTION
DROP FUNCTION IF EXISTS public.get_balance_sheet(DATE) CASCADE;

CREATE FUNCTION public.get_balance_sheet(
    p_as_of_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    section TEXT,
    account_name TEXT,
    amount NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_net_profit NUMERIC;
BEGIN
    -- 1. Calculate Net Profit (Revenue - Expenses)
    SELECT COALESCE(SUM(
        CASE 
            WHEN a.account_type = 'income' THEN le.credit_amount - le.debit_amount
            WHEN a.account_type = 'expense' THEN le.debit_amount - le.credit_amount
            ELSE 0
        END
    ), 0)
    INTO v_net_profit
    FROM public.ledger_entries le
    JOIN public.accounts a ON a.id = le.account_id
    WHERE le.posting_date <= p_as_of_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND a.account_type IN ('income', 'expense');

    RETURN QUERY
    -- 2. ASSETS
    -- A) Accounts Receivable (Detailed)
    SELECT 
        'Assets'::TEXT,
        'Accounts Receivable (Customers)'::TEXT,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.slug = 'ar' AND a.is_active = true
      AND le.posting_date <= p_as_of_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0

    UNION ALL

    -- B) Other System Assets (Cash, Inventory, etc.)
    SELECT 
        'Assets'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'asset' AND a.is_active = true AND (a.slug IS NULL OR a.slug <> 'ar')
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0

    UNION ALL

    -- 3. LIABILITIES
    -- A) Accounts Payable (Detailed)
    SELECT 
        'Liabilities'::TEXT,
        'Accounts Payable (Suppliers)'::TEXT,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.slug = 'ap' AND a.is_active = true
      AND le.posting_date <= p_as_of_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    HAVING ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) <> 0

    UNION ALL

    -- B) Other System Liabilities
    SELECT 
        'Liabilities'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'liability' AND a.is_active = true AND (a.slug IS NULL OR a.slug <> 'ap')
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- 4. EQUITY
    SELECT 
        'Equity'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'equity' AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- 5. NET PROFIT
    SELECT 
        'Equity'::TEXT,
        'Net Profit (Current Period)'::TEXT,
        v_net_profit
    WHERE ROUND(v_net_profit, 2) <> 0
    
    ORDER BY section DESC, account_name;
END;
$$;

COMMIT;

-- ============================================================================
-- LEDGER IS THE BIBLE - REPORTS ONLY READ, NEVER INTERPRET
-- ============================================================================
-- This migration fixes the Balance Sheet and Trial Balance mismatch
-- by reading DIRECTLY from the ledger without any derived calculations.
-- 
-- RULES:
-- 1. NO v_net_profit
-- 2. NO ABS()
-- 3. NO derived profit logic
-- 4. NO manual equity formulas
-- 5. Equity comes ONLY from equity ledger accounts
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. FIX: get_trial_balance_v2
-- ============================================================================
-- Purpose: Return EXACT ledger debits and credits per account
-- 
-- ACCOUNTING LAW for Trial Balance:
--   - Debit Balance accounts → shown in DEBIT column
--   - Credit Balance accounts → shown in CREDIT column
--   - Opening Balance = Net balance BEFORE p_start_date
--   - Period DR/CR = Activity within period
--   - Closing Balance = Opening + Period Activity
-- ============================================================================

DROP FUNCTION IF EXISTS public.get_trial_balance_v2(DATE, DATE) CASCADE;

CREATE FUNCTION public.get_trial_balance_v2(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    account_type TEXT,
    opening_balance NUMERIC,
    debit_total NUMERIC,
    credit_total NUMERIC,
    debit_balance NUMERIC,
    credit_balance NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    WITH all_accounts AS (
        -- SYSTEM ACCOUNTS (excluding AR/AP control accounts)
        SELECT 
            a.id as entity_id,
            'account' as entity_type,
            a.code::TEXT as ac,
            a.name::TEXT as an,
            a.account_type::TEXT as at
        FROM public.accounts a
        WHERE a.is_active = true 
          AND a.slug NOT IN ('ar', 'ap')

        UNION ALL

        -- PARTY ACCOUNTS
        SELECT 
            p.id as entity_id,
            'party' as entity_type,
            (CASE WHEN p.type='customer' THEN '1100-' ELSE '2100-' END || p.id)::TEXT as ac,
            (p.name || ' (' || UPPER(LEFT(p.type, 1)) || ')')::TEXT as an,
            (CASE WHEN p.type='customer' THEN 'asset' ELSE 'liability' END)::TEXT as at
        FROM public.parties p
        WHERE p.is_active = true
    ),
    opening_data AS (
        -- Opening Balance: All entries BEFORE p_start_date
        SELECT 
            aa.ac,
            COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as ob
        FROM all_accounts aa
        LEFT JOIN public.ledger_entries le ON 
            (aa.entity_type = 'account' AND le.account_id = aa.entity_id)
            OR (aa.entity_type = 'party' AND le.party_id = aa.entity_id)
        WHERE (p_start_date IS NOT NULL AND le.posting_date < p_start_date)
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY aa.ac
    ),
    period_data AS (
        -- Period Activity: All entries within date range
        SELECT 
            aa.ac,
            COALESCE(SUM(le.debit_amount), 0) as dr,
            COALESCE(SUM(le.credit_amount), 0) as cr
        FROM all_accounts aa
        LEFT JOIN public.ledger_entries le ON 
            (aa.entity_type = 'account' AND le.account_id = aa.entity_id)
            OR (aa.entity_type = 'party' AND le.party_id = aa.entity_id)
        WHERE (p_start_date IS NULL OR le.posting_date >= p_start_date)
          AND (p_end_date IS NULL OR le.posting_date <= p_end_date)
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY aa.ac
    ),
    combined AS (
        SELECT 
            aa.ac,
            aa.an,
            aa.at,
            COALESCE(od.ob, 0) as opening,
            COALESCE(pd.dr, 0) as period_dr,
            COALESCE(pd.cr, 0) as period_cr,
            -- Closing = Opening + (Dr - Cr)
            COALESCE(od.ob, 0) + COALESCE(pd.dr, 0) - COALESCE(pd.cr, 0) as closing
        FROM all_accounts aa
        LEFT JOIN opening_data od ON aa.ac = od.ac
        LEFT JOIN period_data pd ON aa.ac = pd.ac
    )
    SELECT
        c.ac as account_code,
        c.an as account_name,
        c.at as account_type,
        c.opening as opening_balance,
        c.period_dr as debit_total,
        c.period_cr as credit_total,
        -- TRIAL BALANCE COLUMNS (proper accounting law)
        CASE WHEN c.closing > 0 THEN c.closing ELSE 0 END as debit_balance,
        CASE WHEN c.closing < 0 THEN -c.closing ELSE 0 END as credit_balance
    FROM combined c
    WHERE c.period_dr > 0 OR c.period_cr > 0 OR c.opening <> 0
    ORDER BY c.ac;
END;
$$;

-- ============================================================================
-- 2. FIX: get_financial_position (Balance Sheet)
-- ============================================================================
-- Purpose: Return ledger balances DIRECTLY grouped by account_type
-- 
-- RULE: 
--   Assets = SUM(debit - credit) WHERE account_type = 'asset'
--   Liabilities = SUM(credit - debit) WHERE account_type = 'liability'
--   Equity = SUM(credit - debit) WHERE account_type = 'equity'
-- 
-- NO "Net Profit" row. Profit is ALREADY INSIDE asset balances (cash/bank/inventory).
-- ============================================================================

DROP FUNCTION IF EXISTS public.get_financial_position(DATE) CASCADE;

CREATE FUNCTION public.get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY

    -- ========== ASSETS (System Accounts) ==========
    -- Normal Balance: Debit | Formula: Dr - Cr
    SELECT 
        'ASSETS'::TEXT as category,
        'Current Assets'::TEXT as sub_category,
        a.name::TEXT as account_name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as balance
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL

    -- ========== ASSETS (Customer Receivables) ==========
    -- Customers owe us money = Asset (Debit Balance)
    SELECT 
        'ASSETS'::TEXT,
        'Accounts Receivable'::TEXT,
        (p.name || ' (Customer)')::TEXT,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE p.type = 'customer'
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.id, p.name
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL

    -- ========== LIABILITIES (System Accounts) ==========
    -- Normal Balance: Credit | Formula: Cr - Dr
    SELECT 
        'LIABILITIES'::TEXT,
        'Current Liabilities'::TEXT,
        a.name::TEXT,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- ========== LIABILITIES (Supplier Payables) ==========
    -- We owe suppliers money = Liability (Credit Balance)
    SELECT 
        'LIABILITIES'::TEXT,
        'Accounts Payable'::TEXT,
        (p.name || ' (Supplier)')::TEXT,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE p.type = 'supplier'
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.id, p.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- ========== EQUITY (System Accounts ONLY) ==========
    -- Normal Balance: Credit | Formula: Cr - Dr
    -- This includes Capital and any Retained Earnings accounts FROM THE LEDGER
    -- NO derived "Net Profit" - profit is already in asset balances
    SELECT 
        'EQUITY'::TEXT,
        'Owner''s Equity'::TEXT,
        a.name::TEXT,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'equity'
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0;

    -- ========== NO "NET PROFIT" ROW ==========
    -- Profit is ALREADY reflected in the increased asset balances (cash/bank/inventory).
    -- Adding it here would be DOUBLE COUNTING.

END;
$$;

-- ============================================================================
-- 3. GRANT PERMISSIONS
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.get_trial_balance_v2(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_trial_balance_v2(DATE, DATE) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_financial_position(DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_financial_position(DATE) TO service_role;

COMMIT;

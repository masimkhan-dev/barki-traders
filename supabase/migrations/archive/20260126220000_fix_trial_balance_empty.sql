-- =================================================================
-- FIX TRIAL BALANCE (INCLUDE PARTIES)
-- Purpose: Include Customers and Suppliers in Trial Balance Report
-- Reason: Currently it only queries 'accounts' table, but transaction
--         data is linked to 'parties'.
-- =================================================================

BEGIN;

-- Drop existing function
DROP FUNCTION IF EXISTS public.get_trial_balance_v2(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_trial_balance(DATE, DATE) CASCADE;

-- Re-create with Parties Logic
CREATE FUNCTION public.get_trial_balance_v2(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    account_type TEXT,
    debit NUMERIC,
    credit NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    -- 1. SYSTEM ACCOUNTS (Cash, Expenses, Revenue, etc.)
    SELECT 
        a.code,
        a.name,
        a.account_type,
        COALESCE(SUM(le.debit_amount), 0) as debit,
        COALESCE(SUM(le.credit_amount), 0) as credit
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
        AND le.posting_date <= p_end_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.is_active = true
      AND a.slug NOT IN ('ar', 'ap') -- Exclude control accounts, we will add parties individually below
    GROUP BY a.id, a.code, a.name, a.account_type
    HAVING COALESCE(SUM(le.debit_amount), 0) > 0 OR COALESCE(SUM(le.credit_amount), 0) > 0

    UNION ALL

    -- 2. CUSTOMERS (Map to 1100 AR)
    SELECT 
        '1100-' || p.id::text as code,
        p.name || ' (Customer)',
        'asset' as account_type,
        COALESCE(SUM(le.debit_amount), 0) as debit,
        COALESCE(SUM(le.credit_amount), 0) as credit
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE p.type IN ('customer', 'both')
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.id, p.name

    UNION ALL

    -- 3. SUPPLIERS (Map to 2100 AP)
    SELECT 
        '2100-' || p.id::text as code,
        p.name || ' (Supplier)',
        'liability' as account_type,
        COALESCE(SUM(le.debit_amount), 0) as debit,
        COALESCE(SUM(le.credit_amount), 0) as credit
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE p.type IN ('supplier', 'both')
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.id, p.name

    ORDER BY account_code;
END;
$$;

-- Alias
CREATE FUNCTION public.get_trial_balance(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (account_code TEXT, account_name TEXT, account_type TEXT, debit NUMERIC, credit NUMERIC)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY SELECT * FROM public.get_trial_balance_v2(p_start_date, p_end_date);
END;
$$;

COMMIT;

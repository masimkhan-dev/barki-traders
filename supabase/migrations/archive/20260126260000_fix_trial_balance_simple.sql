-- =================================================================
-- FIX TRIAL BALANCE (DEAD SIMPLE VERSION)
-- Purpose: Remove CTEs and complex logic to eliminate 400 Bad Request
--          caused by ambiguous columns or query plan failures.
-- =================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_trial_balance_v2(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_trial_balance(DATE, DATE) CASCADE;

CREATE FUNCTION public.get_trial_balance_v2(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
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
    -- SYSTEM ACCOUNTS (Direct)
    SELECT 
        a.code::TEXT,
        a.name::TEXT,
        a.account_type::TEXT,
        COALESCE(SUM(le.debit_amount), 0),
        COALESCE(SUM(le.credit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.is_active = true
      AND a.slug NOT IN ('ar', 'ap')
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND (p_end_date IS NULL OR le.posting_date <= (COALESCE(p_end_date, CURRENT_DATE) + INTERVAL '1 day'))
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.code, a.name, a.account_type
    HAVING COALESCE(SUM(le.debit_amount), 0) > 0 OR COALESCE(SUM(le.credit_amount), 0) > 0

    UNION ALL

    -- PARTIES (Direct Join)
    SELECT 
        ('1100-' || p.id)::TEXT,
        (p.name || ' (Customer)')::TEXT,
        'asset'::TEXT,
        COALESCE(SUM(le.debit_amount), 0),
        COALESCE(SUM(le.credit_amount), 0)
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE p.type IN ('customer', 'both')
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND (p_end_date IS NULL OR le.posting_date <= (COALESCE(p_end_date, CURRENT_DATE) + INTERVAL '1 day'))
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.id, p.name

    UNION ALL

    -- SUPPLIERS (Direct Join)
    SELECT 
        ('2100-' || p.id)::TEXT,
        (p.name || ' (Supplier)')::TEXT,
        'liability'::TEXT,
        COALESCE(SUM(le.debit_amount), 0),
        COALESCE(SUM(le.credit_amount), 0)
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE p.type IN ('supplier', 'both')
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND (p_end_date IS NULL OR le.posting_date <= (COALESCE(p_end_date, CURRENT_DATE) + INTERVAL '1 day'))
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.id, p.name;
    
    -- Removed internal ORDER BY to let frontend handle it or default behavior
    -- to avoid ambiguity in UNION result
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

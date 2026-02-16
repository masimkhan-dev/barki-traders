-- =================================================================
-- FIX TRIAL BALANCE DATE ISSUE
-- Purpose: Broaden date logic to handle Timezone mismatches
-- =================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_trial_balance_v2(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_trial_balance(DATE, DATE) CASCADE;

CREATE FUNCTION public.get_trial_balance_v2(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL  -- Changed default to NULL to allow logic override
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
DECLARE
    v_end_date DATE;
BEGIN
    -- Handle End Date (Default to far future to catch everything if not specified, 
    -- or CURRENT_DATE + 1 day to catch timezone movements)
    IF p_end_date IS NULL THEN
        v_end_date := CURRENT_DATE + INTERVAL '1 day';
    ELSE
        v_end_date := p_end_date;
    END IF;

    RETURN QUERY
    WITH ledger_data AS (
        SELECT
            le.account_id,
            le.party_id,
            COALESCE(SUM(le.debit_amount), 0) as dr,
            COALESCE(SUM(le.credit_amount), 0) as cr
        FROM public.ledger_entries le
        WHERE (p_start_date IS NULL OR le.posting_date >= p_start_date)
          AND le.posting_date <= v_end_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY le.account_id, le.party_id
    )
    -- 1. SYSTEM ACCOUNTS
    SELECT
        a.code::TEXT,
        a.name::TEXT,
        a.account_type::TEXT,
        SUM(ld.dr),
        SUM(ld.cr)
    FROM ledger_data ld
    JOIN public.accounts a ON a.id = ld.account_id
    WHERE (ld.party_id IS NULL OR a.slug NOT IN ('ar', 'ap'))
    GROUP BY a.code, a.name, a.account_type

    UNION ALL

    -- 2. PARTIES
    SELECT
        CASE 
            WHEN p.type = 'customer' THEN '1100-' || p.id
            WHEN p.type = 'supplier' THEN '2100-' || p.id
            ELSE '9999-' || p.id
        END::TEXT as code,
        (p.name || ' (' || UPPER(LEFT(p.type, 1)) || ')')::TEXT as name,
        CASE 
            WHEN p.type = 'customer' THEN 'asset'
            ELSE 'liability'
        END::TEXT as type,
        SUM(ld.dr),
        SUM(ld.cr)
    FROM ledger_data ld
    JOIN public.parties p ON p.id = ld.party_id
    JOIN public.accounts a ON a.id = ld.account_id
    WHERE a.slug IN ('ar', 'ap')
    GROUP BY p.id, p.name, p.type

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

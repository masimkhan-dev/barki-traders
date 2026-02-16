-- =================================================================
-- FIX TRIAL BALANCE FINAL (LEDGER FIRST APPROACH)
-- Purpose: Query ledger_entries directly to guarantee data retrieval.
-- Strategy: Don't trust joins. Trust the ledger table.
-- =================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_trial_balance(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_trial_balance_v2(DATE, DATE) CASCADE;

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
    WITH ledger_data AS (
        SELECT
            le.account_id,
            le.party_id,
            COALESCE(SUM(le.debit_amount), 0) as dr,
            COALESCE(SUM(le.credit_amount), 0) as cr
        FROM public.ledger_entries le
        WHERE (p_start_date IS NULL OR le.posting_date >= p_start_date)
          AND le.posting_date <= p_end_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY le.account_id, le.party_id
    )
    -- 1. SYSTEM ACCOUNTS (Where party_id is NULL or effectively ignored for control accts)
    SELECT
        a.code::TEXT,
        a.name::TEXT,
        a.account_type::TEXT,
        SUM(ld.dr),
        SUM(ld.cr)
    FROM ledger_data ld
    JOIN public.accounts a ON a.id = ld.account_id
    WHERE (ld.party_id IS NULL OR a.slug NOT IN ('ar', 'ap')) -- Normal accounts
    GROUP BY a.code, a.name, a.account_type

    UNION ALL

    -- 2. PARTIES (Customers/Suppliers) - Linked via AR/AP Control Accounts
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
    WHERE a.slug IN ('ar', 'ap') -- Only pick up Party balances from Control Accounts
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

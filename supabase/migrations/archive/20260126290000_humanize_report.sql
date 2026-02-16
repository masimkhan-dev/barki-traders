-- =================================================================
-- REVERT TO STANDARD NAMES
-- Purpose: Revert Munshi-friendly names back to Standard Accounting Terms
--          as per user request.
-- =================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_trial_balance_v2(
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
    closing_balance NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    WITH raw_data AS (
        -- SYSTEM ACCOUNTS
        SELECT 
            a.code::TEXT as ac,
            a.name::TEXT as an, -- Original Name
            a.account_type::TEXT as at,
            COALESCE(SUM(le.debit_amount), 0) as dr,
            COALESCE(SUM(le.credit_amount), 0) as cr
        FROM public.accounts a
        LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        WHERE a.is_active = true AND a.slug NOT IN ('ar', 'ap')
          AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
          AND (p_end_date IS NULL OR le.posting_date <= (COALESCE(p_end_date, CURRENT_DATE) + INTERVAL '1 day'))
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY a.id, a.code, a.name, a.account_type

        UNION ALL

        -- PARTIES
        SELECT 
            (CASE WHEN p.type='customer' THEN '1100-' ELSE '2100-' END || p.id)::TEXT,
            (p.name || ' (' || UPPER(LEFT(p.type, 1)) || ')')::TEXT, -- sami (C)
            (CASE WHEN p.type='customer' THEN 'asset' ELSE 'liability' END)::TEXT,
            COALESCE(SUM(le.debit_amount), 0),
            COALESCE(SUM(le.credit_amount), 0)
        FROM public.parties p
        JOIN public.ledger_entries le ON le.party_id = p.id
        WHERE (p_start_date IS NULL OR le.posting_date >= p_start_date)
          AND (p_end_date IS NULL OR le.posting_date <= (COALESCE(p_end_date, CURRENT_DATE) + INTERVAL '1 day'))
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY p.id, p.name, p.type
    )
    SELECT
        ac as account_code,
        an as account_name,
        at as account_type,
        0::NUMERIC as opening_balance,
        dr as debit_total,
        cr as credit_total,
        CASE 
            WHEN at IN ('asset', 'expense') THEN (dr - cr)
            ELSE (cr - dr)
        END as closing_balance
    FROM raw_data
    WHERE dr > 0 OR cr > 0
    ORDER BY ac;
END;
$$;

COMMIT;

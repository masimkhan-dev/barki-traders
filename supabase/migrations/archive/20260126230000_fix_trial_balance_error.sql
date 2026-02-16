-- =================================================================
-- FIX TRIAL BALANCE ERROR (Ambiguity / Return Type)
-- Purpose: Resolve 400 Bad Request by ensuring return types match
--          and column references are unambiguous.
-- =================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_trial_balance_v2(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_trial_balance(DATE, DATE) CASCADE;

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
    WITH tb_data AS (
        -- 1. SYSTEM ACCOUNTS
        SELECT 
            a.code::TEXT as acc_code,
            a.name::TEXT as acc_name,
            a.account_type::TEXT as acc_type,
            COALESCE(SUM(le.debit_amount), 0) as dr,
            COALESCE(SUM(le.credit_amount), 0) as cr
        FROM public.accounts a
        LEFT JOIN public.ledger_entries le ON le.account_id = a.id
            AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
            AND le.posting_date <= p_end_date
            AND (le.is_reversed IS NULL OR le.is_reversed = false)
        WHERE a.is_active = true
          AND a.slug NOT IN ('ar', 'ap')
        GROUP BY a.id, a.code, a.name, a.account_type

        UNION ALL

        -- 2. CUSTOMERS
        SELECT 
            ('1100-' || p.id)::TEXT as acc_code,
            (p.name || ' (Customer)')::TEXT as acc_name,
            'asset'::TEXT as acc_type,
            COALESCE(SUM(le.debit_amount), 0) as dr,
            COALESCE(SUM(le.credit_amount), 0) as cr
        FROM public.parties p
        JOIN public.ledger_entries le ON le.party_id = p.id
        WHERE p.type IN ('customer', 'both')
          AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
          AND le.posting_date <= p_end_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY p.id, p.name

        UNION ALL

        -- 3. SUPPLIERS
        SELECT 
            ('2100-' || p.id)::TEXT as acc_code,
            (p.name || ' (Supplier)')::TEXT as acc_name,
            'liability'::TEXT as acc_type,
            COALESCE(SUM(le.debit_amount), 0) as dr,
            COALESCE(SUM(le.credit_amount), 0) as cr
        FROM public.parties p
        JOIN public.ledger_entries le ON le.party_id = p.id
        WHERE p.type IN ('supplier', 'both')
          AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
          AND le.posting_date <= p_end_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY p.id, p.name
    )
    SELECT * FROM tb_data
    WHERE dr > 0 OR cr > 0
    ORDER BY acc_code;
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

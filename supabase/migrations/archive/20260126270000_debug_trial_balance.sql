-- =================================================================
-- DEBUG TRIAL BALANCE (RAW MODE)
-- Purpose: Remove ALL filters to verify if data exists and is summing
--          correctly. If this shows 0, then the ledger data itself is 0.
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
    -- 1. RAW SYSTEM ACCOUNTS (No Active check, No Date Check for now)
    SELECT 
        a.code::TEXT,
        a.name::TEXT,
        a.account_type::TEXT,
        COALESCE(SUM(le.debit_amount), 0),
        COALESCE(SUM(le.credit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.slug NOT IN ('ar', 'ap')
    GROUP BY a.id, a.code, a.name, a.account_type
    HAVING COALESCE(SUM(le.debit_amount), 0) > 0 OR COALESCE(SUM(le.credit_amount), 0) > 0

    UNION ALL

    -- 2. RAW PARTIES
    SELECT 
        ('1100-' || p.id)::TEXT,
        (p.name || ' (Customer)')::TEXT,
        'asset'::TEXT,
        COALESCE(SUM(le.debit_amount), 0),
        COALESCE(SUM(le.credit_amount), 0)
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE p.type IN ('customer', 'both')
    GROUP BY p.id, p.name

    UNION ALL

    -- 3. RAW SUPPLIERS
    SELECT 
        ('2100-' || p.id)::TEXT,
        (p.name || ' (Supplier)')::TEXT,
        'liability'::TEXT,
        COALESCE(SUM(le.debit_amount), 0),
        COALESCE(SUM(le.credit_amount), 0)
    FROM public.parties p
    JOIN public.ledger_entries le ON le.party_id = p.id
    WHERE p.type IN ('supplier', 'both')
    GROUP BY p.id, p.name;
    
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

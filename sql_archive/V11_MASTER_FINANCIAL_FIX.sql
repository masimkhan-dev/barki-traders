-- ==========================================
-- 🚀 V11 ULTIMATE FINANCIAL RECONCILIATION
-- ==========================================
-- Objective 1: Fix Trial Balance RPC (400 Error due to alias mismatch)
-- Objective 2: Fix Balance Sheet Mismatch (Enforce Net Profit in Equity)
-- Objective 3: Fix Negative Market Values (Lena/Dena properly separated)

BEGIN;

--------------------------------------------------------------------------------
-- 1. ROBUST TRIAL BALANCE V2
--------------------------------------------------------------------------------
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
) AS $$
BEGIN
    RETURN QUERY
    WITH account_activity AS (
        SELECT 
            le.account_id,
            SUM(CASE WHEN le.posting_date < COALESCE(p_start_date, '1900-01-01'::DATE) THEN (le.debit_amount - le.credit_amount) ELSE 0 END) as opening,
            SUM(CASE WHEN le.posting_date >= COALESCE(p_start_date, '1900-01-01'::DATE) AND le.posting_date <= COALESCE(p_end_date, '2100-01-01'::DATE) THEN le.debit_amount ELSE 0 END) as dr_activity,
            SUM(CASE WHEN le.posting_date >= COALESCE(p_start_date, '1900-01-01'::DATE) AND le.posting_date <= COALESCE(p_end_date, '2100-01-01'::DATE) THEN le.credit_amount ELSE 0 END) as cr_activity
        FROM public.ledger_entries le
        WHERE (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY le.account_id
    )
    SELECT 
        a.code::TEXT as account_code,
        a.name::TEXT as account_name,
        a.account_type::TEXT as account_type,
        COALESCE(aa.opening, 0)::NUMERIC as opening_balance,
        COALESCE(aa.dr_activity, 0)::NUMERIC as debit_total,
        COALESCE(aa.cr_activity, 0)::NUMERIC as credit_total,
        (COALESCE(aa.opening, 0) + COALESCE(aa.dr_activity, 0) - COALESCE(aa.cr_activity, 0))::NUMERIC as closing_balance
    FROM public.accounts a
    LEFT JOIN account_activity aa ON a.id = aa.account_id
    WHERE (aa.dr_activity != 0 OR aa.cr_activity != 0 OR aa.opening != 0)
      AND a.code NOT IN ('3950', '3999')
      AND a.name != 'Opening Investment'
    ORDER BY a.code;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

--------------------------------------------------------------------------------
-- 2. ROBUST FINANCIAL POSITION (BALANCE SHEET)
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_financial_position(DATE);

CREATE OR REPLACE FUNCTION public.get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE 
    v_net_profit NUMERIC;
    v_total_receivables NUMERIC;
    v_total_payables NUMERIC;
BEGIN
    -- 1. Net Profit Calculation (Income - Expenses)
    SELECT COALESCE(SUM(
        CASE 
            WHEN a.account_type::TEXT ILIKE 'income' THEN le.credit_amount - le.debit_amount
            WHEN a.account_type::TEXT ILIKE 'expense' THEN le.credit_amount - le.debit_amount
            ELSE 0
        END
    ), 0)
    INTO v_net_profit
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id 
    WHERE a.account_type::TEXT ILIKE ANY (ARRAY['income', 'expense'])
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    -- 2. Party Balances (From Market Position Helper)
    SELECT 
        COALESCE(SUM(receivable_balance), 0), 
        COALESCE(SUM(payable_balance), 0)
    INTO v_total_receivables, v_total_payables
    FROM get_market_position_report(p_date);

    RETURN QUERY
    -- A. ASSETS (Cash, Bank, Fixed Assets - EXCLUDE AR Control)
    SELECT 
        'ASSETS'::TEXT as category, 
        'Current'::TEXT as sub_category, 
        a.name::TEXT as account_name, 
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as balance
    FROM public.accounts a 
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'asset'
      AND COALESCE(a.slug, '') NOT IN ('ar', 'accounts_receivable')
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name 
    HAVING (COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0) 
       OR (a.code IN ('1000', '1010')) -- Force Cash and Bank to show

    UNION ALL
    -- A2. Market Receivables (Lena)
    SELECT 'ASSETS'::TEXT, 'Current Assets'::TEXT, 'Total Market Receivables (Lena)'::TEXT, v_total_receivables
    WHERE v_total_receivables <> 0

    UNION ALL
    -- B. LIABILITIES (EXCLUDE AP Control)
    SELECT 
        'LIABILITIES'::TEXT as category, 
        'Liabilities'::TEXT as sub_category, 
        a.name::TEXT as account_name, 
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0) as balance
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'liability'
      AND COALESCE(a.slug, '') NOT IN ('ap', 'accounts_payable')
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name 
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0

    UNION ALL
    -- B2. Supplier Payables (Dena)
    SELECT 'LIABILITIES'::TEXT, 'Liabilities'::TEXT, 'Total Supplier Payables (Dena)'::TEXT, v_total_payables
    WHERE v_total_payables <> 0

    UNION ALL
    -- C. EQUITY
    SELECT 
        'EQUITY'::TEXT as category, 
        'Equity & Reserves'::TEXT as sub_category, 
        a.name::TEXT as account_name, 
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0) as balance
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_date
    WHERE a.account_type::TEXT ILIKE 'equity'
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    -- D. NET PROFIT (MANDATORY FOR BALANCE)
    SELECT 'EQUITY'::TEXT, 'Equity & Reserves'::TEXT, 'Net Profit'::TEXT, COALESCE(v_net_profit, 0);

END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMIT;

BEGIN;

-- 1. DATA REPAIR: Fix Cash Account (Critical for Balance Sheet)
-- This moves Cash from P&L back to Balance Sheet
UPDATE public.accounts 
SET account_type = 'asset', 
    slug = 'cash-on-hand' 
WHERE name ILIKE '%Cash%' AND account_type = 'expense';

-- 2. DATA REPAIR: Fix Known Expense Account
-- Ensures the 15k expense is categorized correctly
UPDATE public.accounts 
SET account_type = 'expense' 
WHERE id IN (
    SELECT account_id FROM public.ledger_entries 
    WHERE voucher_no = 'EXP-20260130-0007' AND debit_amount > 0
);

-- 3. RECREATE BALANCE SHEET FUNCTION
DROP FUNCTION IF EXISTS public.get_financial_position(DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_financial_position(p_date DATE) CASCADE;

CREATE OR REPLACE FUNCTION public.get_financial_position(p_date DATE)
RETURNS TABLE (category TEXT, sub_category TEXT, account_name TEXT, balance NUMERIC) 
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
    v_net_profit NUMERIC; 
    v_total_assets NUMERIC; 
    v_total_liabilities NUMERIC; 
    v_equity_balancing NUMERIC;
BEGIN
    -- 1. Calculate Net Profit (Income - Expenses)
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0) INTO v_net_profit
    FROM public.ledger_entries le 
    JOIN public.accounts a ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense') 
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = FALSE);

    -- 2. Calculate Total Assets
    SELECT COALESCE(SUM(val), 0) INTO v_total_assets FROM (
        -- System Assets
        SELECT SUM(le.debit_amount - le.credit_amount) as val
        FROM public.accounts a 
        JOIN public.ledger_entries le ON a.id = le.account_id 
        WHERE a.account_type = 'asset' 
          AND (a.slug IS NULL OR a.slug NOT IN ('ar', 'ap')) 
          AND le.posting_date <= p_date 
          AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
        GROUP BY a.id
        UNION ALL
        -- Receivables
        SELECT (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) 
        FROM public.parties p 
        LEFT JOIN public.ledger_entries le ON p.id = le.party_id AND le.posting_date <= p_date 
          AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
        WHERE p.type IN ('customer', 'both') 
        GROUP BY p.id, p.opening_balance
    ) s1;

    -- 3. Calculate Total Liabilities
    SELECT COALESCE(SUM(val), 0) INTO v_total_liabilities FROM (
        -- System Liabilities
        SELECT SUM(le.credit_amount - le.debit_amount) as val
        FROM public.accounts a 
        JOIN public.ledger_entries le ON a.id = le.account_id 
        WHERE a.account_type = 'liability' 
          AND le.posting_date <= p_date 
          AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
        GROUP BY a.id
        UNION ALL
        -- Payables
        SELECT ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.credit_amount - le.debit_amount), 0))
        FROM public.parties p 
        LEFT JOIN public.ledger_entries le ON p.id = le.party_id AND le.posting_date <= p_date 
          AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
        WHERE p.type IN ('supplier', 'both') 
        GROUP BY p.id, p.opening_balance
        HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.credit_amount - le.debit_amount), 0)) < -0.01
    ) s2;

    -- 4. Calculate Balancing Capital
    v_equity_balancing := v_total_assets - v_total_liabilities - v_net_profit;

    -- 5. Return Report Query
    RETURN QUERY
    -- ASSETS
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT, CAST(SUM(le.debit_amount - le.credit_amount) AS NUMERIC) 
    FROM public.accounts a JOIN public.ledger_entries le ON a.id = le.account_id 
    WHERE a.account_type = 'asset' AND (a.slug IS NULL OR a.slug NOT IN ('ar', 'ap')) 
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
    GROUP BY a.id, a.name 
    HAVING ABS(SUM(le.debit_amount - le.credit_amount)) > 0.01

    UNION ALL
    -- RECEIVABLES
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT, 
           CAST((COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) AS NUMERIC) 
    FROM public.parties p 
    LEFT JOIN public.ledger_entries le ON p.id = le.party_id AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
    WHERE p.type IN ('customer', 'both') 
    GROUP BY p.id, p.name, p.opening_balance 
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) > 0.01

    UNION ALL
    -- PAYABLES
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT, 
           CAST(ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.credit_amount - le.debit_amount), 0)) AS NUMERIC) 
    FROM public.parties p 
    LEFT JOIN public.ledger_entries le ON p.id = le.party_id AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
    WHERE p.type IN ('supplier', 'both') 
    GROUP BY p.id, p.name, p.opening_balance 
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.credit_amount - le.debit_amount), 0)) < -0.01

    UNION ALL
    -- OTHER LIABILITIES
    SELECT 'LIABILITIES'::TEXT, 'Other'::TEXT, a.name::TEXT, 
           CAST(SUM(le.credit_amount - le.debit_amount) AS NUMERIC) 
    FROM public.accounts a 
    JOIN public.ledger_entries le ON a.id = le.account_id 
    WHERE a.account_type = 'liability' 
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = FALSE) 
    GROUP BY a.id, a.name

    UNION ALL
    -- EQUITY
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, 'Opening Investment'::TEXT, CAST(v_equity_balancing AS NUMERIC)
    UNION ALL
    SELECT 'EQUITY'::TEXT, 'Profit'::TEXT, 'Accumulated Net Profit'::TEXT, CAST(v_net_profit AS NUMERIC);
END;
$$;

COMMIT;

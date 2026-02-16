-- =================================================================
-- SYSTEM REVIVAL MIGRATION - RESTORE YESTERDAY'S WORKING STATE
-- Purpose: Fix broken reports, P&L, Ledger, and Listing queries
-- =================================================================

BEGIN;

-- =================================================================
-- 1. FIX PROFIT & LOSS (No Double Counting)
-- =================================================================

DROP FUNCTION IF EXISTS public.get_profit_loss(DATE, DATE) CASCADE;

CREATE FUNCTION public.get_profit_loss(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    section TEXT,
    account_name TEXT,
    amount NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    -- Income
    SELECT 
        'Income'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'income' AND a.is_active = true
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    
    UNION ALL
    
    -- Direct Costs (COGS Only)
    SELECT 
        'Direct Costs'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE (a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%Cost of Goods%')
      AND a.is_active = true
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    
    UNION ALL
    
    -- Operating Expenses (Everything EXCEPT COGS)
    SELECT 
        'Expenses'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense'
      AND a.slug != 'cogs' AND a.code != '4100' AND a.name NOT ILIKE '%Cost of Goods%'
      AND a.is_active = true
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name;
END;
$$;

-- =================================================================
-- 2. FIX TRIAL BALANCE (Show non-zero accounts correctly)
-- =================================================================

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
    GROUP BY a.id, a.code, a.name, a.account_type
    HAVING COALESCE(SUM(le.debit_amount), 0) > 0 OR COALESCE(SUM(le.credit_amount), 0) > 0
    ORDER BY a.code;
END;
$$;

-- Backward compatibility
CREATE FUNCTION public.get_trial_balance(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (account_code TEXT, account_name TEXT, account_type TEXT, debit NUMERIC, credit NUMERIC)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY SELECT * FROM public.get_trial_balance_v2(p_start_date, p_end_date);
END;
$$;

-- =================================================================
-- 3. FIX SALES & PURCHASE REPORTS (Show list nicely)
-- =================================================================

DROP FUNCTION IF EXISTS public.get_sales_report(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_purchases_report(DATE, DATE) CASCADE;

CREATE FUNCTION public.get_sales_report(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    sale_date DATE,
    voucher_no TEXT,
    party_name TEXT,
    fuel_type TEXT,
    quantity NUMERIC,
    rate NUMERIC,
    total_amount NUMERIC,
    is_credit BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        s.sale_date,
        s.voucher_no,
        COALESCE(p.name, 'Cash Customer') as party_name,
        COALESCE(ft.name, 'Unknown Fuel') as fuel_type,
        s.quantity,
        s.rate_per_unit,
        s.total_amount,
        s.is_credit
    FROM public.sales s
    LEFT JOIN public.parties p ON p.id = s.party_id
    LEFT JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
    WHERE (p_start_date IS NULL OR s.sale_date >= p_start_date)
      AND (p_end_date IS NULL OR s.sale_date <= p_end_date)
    ORDER BY s.sale_date DESC, s.created_at DESC;
END;
$$;

CREATE FUNCTION public.get_purchases_report(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    purchase_date DATE,
    voucher_no TEXT,
    party_name TEXT,
    fuel_type TEXT,
    quantity NUMERIC,
    rate NUMERIC,
    total_amount NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        pu.purchase_date,
        pu.voucher_no,
        COALESCE(p.name, 'Unknown Supplier') as party_name,
        COALESCE(ft.name, 'Unknown Fuel') as fuel_type,
        pu.quantity,
        pu.rate_per_unit,
        pu.total_amount
    FROM public.purchases pu
    LEFT JOIN public.parties p ON p.id = pu.party_id
    LEFT JOIN public.fuel_types ft ON ft.id = pu.fuel_type_id
    WHERE (p_start_date IS NULL OR pu.purchase_date >= p_start_date)
      AND (p_end_date IS NULL OR pu.purchase_date <= p_end_date)
    ORDER BY pu.purchase_date DESC, pu.created_at DESC;
END;
$$;

-- =================================================================
-- 4. FIX BALANCE SHEET (Match Assets = Liab + Equity)
-- =================================================================

DROP FUNCTION IF EXISTS public.get_balance_sheet(DATE) CASCADE;

CREATE FUNCTION public.get_balance_sheet(
    p_as_of_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    section TEXT,
    account_name TEXT,
    amount NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_net_profit NUMERIC;
BEGIN
    -- Calc Net Profit (Income - Expense)
    SELECT COALESCE(SUM(
        CASE 
            WHEN a.account_type = 'income' THEN le.credit_amount - le.debit_amount
            WHEN a.account_type = 'expense' THEN le.debit_amount - le.credit_amount
            ELSE 0
        END
    ), 0)
    INTO v_net_profit
    FROM public.ledger_entries le
    JOIN public.accounts a ON a.id = le.account_id
    WHERE le.posting_date <= p_as_of_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND a.account_type IN ('income', 'expense');

    RETURN QUERY
    -- Assets
    SELECT 'Assets'::TEXT, a.name, COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset' AND le.posting_date <= p_as_of_date AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    UNION ALL
    -- Liabilities
    SELECT 'Liabilities'::TEXT, a.name, COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability' AND le.posting_date <= p_as_of_date AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    -- Equity (Owners)
    SELECT 'Equity'::TEXT, a.name, COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'equity' AND le.posting_date <= p_as_of_date AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    -- Net Profit Entry
    SELECT 'Equity'::TEXT, 'Net Profit (Current Period)', v_net_profit;
END;
$$;

COMMIT;

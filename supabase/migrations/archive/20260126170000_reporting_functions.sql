-- =================================================================
-- REPORTING FUNCTIONS PATCH
-- Purpose: Add all missing RPC functions for frontend reports
-- =================================================================

BEGIN;

-- Drop existing functions to avoid signature conflicts
DROP FUNCTION IF EXISTS public.get_trial_balance_v2(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_trial_balance(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_balance_sheet(DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_profit_loss(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_stock_movement(DATE, DATE, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.get_sales_report(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_purchases_report(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_payments_report(DATE, DATE, TEXT) CASCADE;

-- =================================================================
-- FUNCTION 1: TRIAL BALANCE
-- =================================================================

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
        a.code as account_code,
        a.name as account_name,
        a.account_type,
        COALESCE(SUM(le.debit_amount), 0) as debit,
        COALESCE(SUM(le.credit_amount), 0) as credit
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
        AND le.posting_date <= p_end_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.is_active = true
    GROUP BY a.id, a.code, a.name, a.account_type
    HAVING COALESCE(SUM(le.debit_amount), 0) <> 0 OR COALESCE(SUM(le.credit_amount), 0) <> 0
    ORDER BY a.code;
END;
$$;

-- Alias for backward compatibility
CREATE FUNCTION public.get_trial_balance(
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
    SELECT * FROM public.get_trial_balance_v2(p_start_date, p_end_date);
END;
$$;

-- =================================================================
-- FUNCTION 2: BALANCE SHEET
-- =================================================================

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
    -- Calculate Net Profit (Income - Expenses)
    SELECT 
        COALESCE(SUM(
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
      AND COALESCE(le.is_reversed, false) = false
      AND a.account_type IN ('income', 'expense');

    -- Return Assets
    RETURN QUERY
    SELECT 
        'Assets'::TEXT as section,
        a.name as account_name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as amount
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.account_type = 'asset'
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    UNION ALL
    
    -- Return Liabilities
    SELECT 
        'Liabilities'::TEXT as section,
        a.name as account_name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0) as amount
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.account_type = 'liability'
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- Return Equity
    SELECT 
        'Equity'::TEXT as section,
        a.name as account_name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0) as amount
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.account_type = 'equity'
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- Add Net Profit to Equity section
    SELECT 
        'Equity'::TEXT as section,
        'Net Profit (Current Period)'::TEXT as account_name,
        v_net_profit as amount
    WHERE v_net_profit <> 0
    
    ORDER BY section DESC, account_name;
END;
$$;

-- =================================================================
-- FUNCTION 3: PROFIT & LOSS
-- =================================================================

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
    -- Income Section
    SELECT 
        'Income'::TEXT as section,
        a.name as account_name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0) as amount
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
        AND le.posting_date <= p_end_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.account_type = 'income'
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- Expense Section
    SELECT 
        'Expenses'::TEXT as section,
        a.name as account_name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as amount
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
        AND le.posting_date <= p_end_date
        AND COALESCE(le.is_reversed, false) = false
    WHERE a.account_type = 'expense'
      AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    ORDER BY section DESC, account_name;
END;
$$;

-- =================================================================
-- FUNCTION 4: STOCK MOVEMENT REPORT
-- =================================================================

CREATE FUNCTION public.get_stock_movement(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT CURRENT_DATE,
    p_fuel_type_id UUID DEFAULT NULL
)
RETURNS TABLE (
    fuel_type_name TEXT,
    opening_stock NUMERIC,
    purchases NUMERIC,
    sales NUMERIC,
    closing_stock NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ft.name as fuel_type_name,
        -- Opening stock (inventory at start date)
        COALESCE((
            SELECT i.quantity 
            FROM public.inventory i 
            WHERE i.fuel_type_id = ft.id
        ), 0) - COALESCE((
            SELECT SUM(s.quantity)
            FROM public.sales s
            WHERE s.fuel_type_id = ft.id
              AND s.sale_date >= COALESCE(p_start_date, '1900-01-01')
              AND s.sale_date <= p_end_date
        ), 0) + COALESCE((
            SELECT SUM(p.quantity)
            FROM public.purchases p
            WHERE p.fuel_type_id = ft.id
              AND p.purchase_date >= COALESCE(p_start_date, '1900-01-01')
              AND p.purchase_date <= p_end_date
        ), 0) as opening_stock,
        
        -- Purchases in period
        COALESCE((
            SELECT SUM(p.quantity)
            FROM public.purchases p
            WHERE p.fuel_type_id = ft.id
              AND (p_start_date IS NULL OR p.purchase_date >= p_start_date)
              AND p.purchase_date <= p_end_date
        ), 0) as purchases,
        
        -- Sales in period
        COALESCE((
            SELECT SUM(s.quantity)
            FROM public.sales s
            WHERE s.fuel_type_id = ft.id
              AND (p_start_date IS NULL OR s.sale_date >= p_start_date)
              AND s.sale_date <= p_end_date
        ), 0) as sales,
        
        -- Closing stock (current inventory)
        COALESCE((
            SELECT i.quantity 
            FROM public.inventory i 
            WHERE i.fuel_type_id = ft.id
        ), 0) as closing_stock
        
    FROM public.fuel_types ft
    WHERE (p_fuel_type_id IS NULL OR ft.id = p_fuel_type_id)
      AND ft.is_active = true
    ORDER BY ft.name;
END;
$$;

-- =================================================================
-- FUNCTION 5: SALES REPORT
-- =================================================================

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
        p.name as party_name,
        ft.name as fuel_type,
        s.quantity,
        s.rate_per_unit as rate,
        s.total_amount,
        s.is_credit
    FROM public.sales s
    LEFT JOIN public.parties p ON p.id = s.party_id
    LEFT JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
    WHERE (p_start_date IS NULL OR s.sale_date >= p_start_date)
      AND s.sale_date <= p_end_date
    ORDER BY s.sale_date DESC, s.created_at DESC;
END;
$$;

-- =================================================================
-- FUNCTION 6: PURCHASES REPORT
-- =================================================================

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
        p.purchase_date,
        p.voucher_no,
        pt.name as party_name,
        ft.name as fuel_type,
        p.quantity,
        p.rate_per_unit as rate,
        p.total_amount
    FROM public.purchases p
    LEFT JOIN public.parties pt ON pt.id = p.party_id
    LEFT JOIN public.fuel_types ft ON ft.id = p.fuel_type_id
    WHERE (p_start_date IS NULL OR p.purchase_date >= p_start_date)
      AND p.purchase_date <= p_end_date
    ORDER BY p.purchase_date DESC, p.created_at DESC;
END;
$$;

-- =================================================================
-- FUNCTION 7: PAYMENTS REPORT
-- =================================================================

CREATE FUNCTION public.get_payments_report(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT CURRENT_DATE,
    p_payment_type TEXT DEFAULT NULL
)
RETURNS TABLE (
    payment_date DATE,
    voucher_no TEXT,
    payment_type TEXT,
    party_name TEXT,
    amount NUMERIC,
    method TEXT,
    notes TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        pm.payment_date,
        pm.voucher_no,
        pm.payment_type,
        p.name as party_name,
        pm.amount,
        pm.method,
        pm.notes
    FROM public.payments pm
    LEFT JOIN public.parties p ON p.id = pm.party_id
    WHERE (p_start_date IS NULL OR pm.payment_date >= p_start_date)
      AND pm.payment_date <= p_end_date
      AND (p_payment_type IS NULL OR pm.payment_type = p_payment_type)
    ORDER BY pm.payment_date DESC, pm.created_at DESC;
END;
$$;

-- =================================================================
-- VALIDATION
-- =================================================================

DO $$
DECLARE
    v_function_count INT;
BEGIN
    SELECT COUNT(*) INTO v_function_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'get_trial_balance',
          'get_trial_balance_v2',
          'get_balance_sheet',
          'get_profit_loss',
          'get_stock_movement',
          'get_party_statement',
          'get_sales_report',
          'get_purchases_report',
          'get_payments_report'
      );
    
    IF v_function_count < 9 THEN
        RAISE EXCEPTION 'VALIDATION FAILED: Missing reporting functions';
    END IF;
    
    RAISE NOTICE '✅ All % reporting functions created successfully', v_function_count;
END $$;

COMMIT;

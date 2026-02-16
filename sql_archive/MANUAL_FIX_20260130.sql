BEGIN;

-- =================================================================
-- 1. DROP CONFLICTING FUNCTIONS FIRST
-- =================================================================
-- We must drop the old version first because we are changing the return type.
-- The error "42P13" (cannot change return type) happens when we try to replace
-- a function with a new RETURN TABLE structure without dropping it first.

DROP FUNCTION IF EXISTS public.get_trial_balance(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_trial_balance_v2(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_profit_loss(DATE, DATE) CASCADE;
DROP FUNCTION IF EXISTS public.get_financial_position(DATE) CASCADE;

-- =================================================================
-- 2. FIX DATA TYPES (Fixes P&L Double Counting)
-- =================================================================
UPDATE public.accounts 
SET account_type = 'asset', slug = 'inventory' 
WHERE (name ILIKE '%Fuel Purchase Cost%' OR name ILIKE '%Inventory%')
  AND account_type = 'expense';

UPDATE public.accounts 
SET account_type = 'expense', slug = 'cogs' 
WHERE (name ILIKE '%Cost of Goods Sold%' OR slug = 'cogs')
  AND account_type != 'expense';

-- =================================================================
-- 3. FIX TABLE STRUCTURE (Daily Book Fix)
-- =================================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'ledger_entries' AND column_name = 'reconciliation_status'
    ) THEN
        ALTER TABLE public.ledger_entries ADD COLUMN reconciliation_status BOOLEAN DEFAULT false;
        ALTER TABLE public.ledger_entries ADD COLUMN reconciled_at TIMESTAMPTZ;
    END IF;
END $$;

-- =================================================================
-- 4. RECREATE TRIAL BALANCE FUNCTION (Clean Slate)
-- =================================================================
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
            a.name::TEXT as an,
            a.account_type::TEXT as at,
            COALESCE(SUM(le.debit_amount), 0) as dr,
            COALESCE(SUM(le.credit_amount), 0) as cr
        FROM public.accounts a
        LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        WHERE a.is_active = true AND a.slug NOT IN ('ar', 'ap')
          AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
          AND (p_end_date IS NULL OR le.posting_date <= (p_end_date + INTERVAL '1 day'))
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY a.id, a.code, a.name, a.account_type

        UNION ALL

        -- PARTIES
        SELECT 
            (CASE WHEN p.type='customer' THEN '1100-' ELSE '2100-' END || p.id)::TEXT,
            (p.name || ' (' || UPPER(LEFT(p.type, 1)) || ')')::TEXT,
            (CASE WHEN p.type='customer' THEN 'asset' ELSE 'liability' END)::TEXT,
            COALESCE(SUM(le.debit_amount), 0),
            COALESCE(SUM(le.credit_amount), 0)
        FROM public.parties p
        JOIN public.ledger_entries le ON le.party_id = p.id
        WHERE (p_start_date IS NULL OR le.posting_date >= p_start_date)
          AND (p_end_date IS NULL OR le.posting_date <= (p_end_date + INTERVAL '1 day'))
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
        (dr - cr) as closing_balance
    FROM raw_data
    WHERE dr > 0 OR cr > 0
    ORDER BY ac;
END;
$$;

-- Alias
CREATE OR REPLACE FUNCTION public.get_trial_balance(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (account_code TEXT, account_name TEXT, account_type TEXT, opening_balance NUMERIC, debit_total NUMERIC, credit_total NUMERIC, closing_balance NUMERIC)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY SELECT * FROM public.get_trial_balance_v2(p_start_date, p_end_date);
END;
$$;

-- =================================================================
-- 5. RECREATE P&L FUNCTION (Clean Slate)
-- =================================================================
CREATE OR REPLACE FUNCTION public.get_profit_loss(
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
    -- A. INCOME
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
    HAVING ROUND(COALESCE(SUM(le.credit_amount - le.debit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- B. DIRECT COSTS
    SELECT 
        'Direct Costs'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense' 
      AND (a.slug = 'cogs' OR a.code = '4100' OR a.name ILIKE '%Cost of Goods Sold%')
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0
    
    UNION ALL
    
    -- C. OPERATING EXPENSES
    SELECT 
        'Expenses'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a 
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'expense' AND a.is_active = true
      AND COALESCE(a.slug, '') <> 'cogs'
      AND a.code <> '4100'
      AND a.name NOT ILIKE '%Cost of Goods Sold%'
      AND (p_start_date IS NULL OR le.posting_date >= p_start_date)
      AND le.posting_date <= p_end_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name
    HAVING ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) <> 0;
END;
$$;

-- =================================================================
-- 6. RECREATE BALANCE SHEET FUNCTION
-- =================================================================
CREATE OR REPLACE FUNCTION public.get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE
    v_net_profit NUMERIC;
BEGIN
    -- 1. Calculate Net Profit (Income - Expense)
    -- Income (Cr) - Expense (Dr)
    -- Result: Positive = Profit, Negative = Loss
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_net_profit
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    RETURN QUERY
    -- 2. ASSETS (System Accounts)
    -- Cash, Bank, Inventory, Fixed Assets
    -- Formula: Dr - Cr
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND a.slug NOT IN ('ar', 'ap') -- Exclude control accounts if they exist, to avoid duplication with Parties
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL

    -- 3. ASSETS (Customers - Receivables)
    -- Parties of type 'customer' are Assets
    -- Formula: Dr (Receivable) - Cr (Received)
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, (p.name || ' (Customer)')::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM parties p
    JOIN ledger_entries le ON le.party_id = p.id
    WHERE p.type = 'customer'
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.name, p.type
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL

    -- 4. LIABILITIES (System Accounts)
    -- Loans, Tax Payable, etc.
    -- Formula: Cr - Dr
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 5. LIABILITIES (Suppliers - Payables)
    -- Parties of type 'supplier' are Liabilities
    -- Formula: Cr (Payable) - Dr (Paid)
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, (p.name || ' (Supplier)')::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM parties p
    JOIN ledger_entries le ON le.party_id = p.id
    WHERE p.type = 'supplier'
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.name, p.type
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 6. EQUITY (System Accounts)
    -- Capital, etc. (Excluding Retained Earnings which is calc'd below)
    -- Formula: Cr - Dr
    SELECT 'EQUITY'::TEXT, 'Owner Capital'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE (a.account_type = 'equity' OR a.code = '3000') 
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 7. RETAINED EARNINGS (Calculated Net Profit)
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Net Profit'::TEXT, v_net_profit;
END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;

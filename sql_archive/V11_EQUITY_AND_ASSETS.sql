-- V11 EQUITY AND ASSET REPORTING (HARDENED)
-- Purpose: Track Owner's Capital movements and Fixed Asset values with high audit accuracy.

-- 1. PROPRIETOR CAPITAL LEDGER
CREATE OR REPLACE FUNCTION get_owner_capital_report(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    posting_date DATE,
    voucher_no TEXT,
    narration TEXT,
    debit NUMERIC,
    credit NUMERIC,
    running_balance NUMERIC
) AS $$
DECLARE
    v_opening_balance NUMERIC := 0;
    v_capital_acc_ids UUID[];
BEGIN
    -- 1. Identify all Capital/Equity accounts
    SELECT array_agg(id) INTO v_capital_acc_ids FROM public.accounts 
    WHERE account_type = 'equity' 
       OR slug IN ('capital', 'owner-capital', 'drawings') 
       OR name ILIKE '%Capital%' 
       OR name ILIKE '%Drawings%';

    -- 2. Calculate Cumulative Opening Balance (Prior to start date)
    SELECT COALESCE(SUM(credit_amount - debit_amount), 0) INTO v_opening_balance
    FROM public.ledger_entries
    WHERE account_id = ANY(v_capital_acc_ids) 
      AND posting_date < p_start_date
      AND (is_reversed IS NULL OR is_reversed = false);

    -- 3. Return Transactions with Period Running Balance
    RETURN QUERY
    WITH tx AS (
        SELECT 
            le.posting_date,
            le.voucher_no,
            le.narration,
            le.debit_amount,
            le.credit_amount,
            le.created_at,
            -- Period running sum
            SUM(le.credit_amount - le.debit_amount) OVER (ORDER BY le.posting_date, le.created_at) as period_running
        FROM public.ledger_entries le
        WHERE le.account_id = ANY(v_capital_acc_ids) 
          AND le.posting_date >= p_start_date 
          AND le.posting_date <= p_end_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
    )
    SELECT 
        t.posting_date,
        t.voucher_no,
        t.narration,
        t.debit_amount,
        t.credit_amount,
        (v_opening_balance + t.period_running) as running_balance
    FROM tx t
    ORDER BY t.posting_date ASC, t.created_at ASC;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


-- 2. FIXED ASSET REGISTER
CREATE OR REPLACE FUNCTION get_fixed_assets_report()
RETURNS TABLE (
    account_name TEXT,
    original_value NUMERIC,
    depreciation NUMERIC,
    net_value NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        a.name as account_name,
        -- Debits increase asset value (Purchase)
        COALESCE(SUM(CASE WHEN le.debit_amount > 0 THEN le.debit_amount ELSE 0 END), 0) as original_value,
        -- Credits decrease asset value (Depreciation/Sale)
        COALESCE(SUM(CASE WHEN le.credit_amount > 0 THEN le.credit_amount ELSE 0 END), 0) as depreciation,
        -- Net Book Value
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as net_value
    FROM public.accounts a
    JOIN public.ledger_entries le ON a.id = le.account_id
    WHERE a.account_type = 'asset' 
      AND (a.sub_category ILIKE '%Fixed%' OR a.slug ILIKE '%fixed-asset%' OR a.name ILIKE '%Furniture%' OR a.name ILIKE '%Building%' OR a.name ILIKE '%Vehicle%')
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

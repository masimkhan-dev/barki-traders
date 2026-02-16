-- =================================================================
-- ULTIMATE BALANCE SHEET FIX
-- Fixes: 1) Reversal inflation (89k->39k), 2) Missing party payables, 3) Owner's Capital
-- =================================================================

BEGIN;

CREATE OR REPLACE FUNCTION get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE
    v_net_profit NUMERIC;
    v_total_assets NUMERIC;
    v_total_liabilities NUMERIC;
    v_owner_capital NUMERIC;
BEGIN
    -- Calculate Net Profit (exclude reversed AND reversal entries)
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_net_profit
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND le.reversal_of_voucher IS NULL;  -- KEY FIX: Exclude reversal entries too

    RETURN QUERY
    -- 1. SYSTEM ASSETS (exclude both reversed and reversal entries)
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND le.reversal_of_voucher IS NULL  -- KEY FIX
    GROUP BY a.name
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL

    -- 2. PARTY ASSETS (Receivables)
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT,
           (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) as total_bal
    FROM public.parties p
    LEFT JOIN public.ledger_entries le ON le.party_id = p.id 
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND le.reversal_of_voucher IS NULL
    WHERE p.type = 'customer'
    GROUP BY p.id, p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) > 0

    UNION ALL

    -- 3. LIABILITIES (System Accounts)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND le.reversal_of_voucher IS NULL
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 4. PARTY LIABILITIES (Payables) - FIXED LOGIC
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT,
           ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) as total_bal
    FROM public.parties p
    LEFT JOIN public.ledger_entries le ON le.party_id = p.id 
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND le.reversal_of_voucher IS NULL
    WHERE p.type = 'supplier'  -- KEY FIX: Filter by supplier type
    GROUP BY p.id, p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) < 0

    UNION ALL

    -- 5. EQUITY (Manual entries if any)
    SELECT 'EQUITY'::TEXT, 'Owner Capital'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE (a.account_type = 'equity' OR a.code = '3000') 
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND le.reversal_of_voucher IS NULL
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 6. Net Profit
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Net Profit'::TEXT, v_net_profit
    WHERE v_net_profit <> 0;
END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;

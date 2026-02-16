-- =================================================================
-- FINAL ULTIMATE REPAIR: BALANCE SHEET & DASHBOARD INTEGRITY
-- Purpose: 
-- 1. Universal Balance Sheet (No exclusions, group by name)
-- 2. Ledger-based Dashboard (No more stale columns)
-- 3. Party-aware Munshi Vouchers (Dr/Cr correct control accounts)
-- =================================================================

BEGIN;

-- =================================================================
-- 1. UNIVERSAL BALANCE SHEET (ROBUST & HONEST)
-- =-- No more slug-based exclusions. If it is an Asset, show it.
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
    -- Calc Net Profit (Matched to Profit & Loss Logic)
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
    -- A. ASSETS (All accounts of type 'asset')
    SELECT 
        'Assets'::TEXT,
        a.name,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'asset' AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0
    
    UNION ALL
    
    -- B. LIABILITIES (All accounts of type 'liability')
    SELECT 
        'Liabilities'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'liability' AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- C. EQUITY (All accounts of type 'equity')
    SELECT 
        'Equity'::TEXT,
        a.name,
        COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON le.account_id = a.id
        AND le.posting_date <= p_as_of_date
        AND (le.is_reversed IS NULL OR le.is_reversed = false)
    WHERE a.account_type = 'equity' AND a.is_active = true
    GROUP BY a.id, a.name
    HAVING COALESCE(SUM(le.credit_amount - le.debit_amount), 0) <> 0
    
    UNION ALL
    
    -- D. NET PROFIT (Current Period)
    SELECT 
        'Equity'::TEXT,
        'Net Profit (Current Period)'::TEXT,
        v_net_profit
    WHERE v_net_profit <> 0
    
    ORDER BY section DESC, account_name;
END;
$$;

-- =================================================================
-- 2. LEDGER-BASED DASHBOARD (REAL-TIME ACCURACY)
-- =================================================================

CREATE OR REPLACE FUNCTION get_dashboard_v10_analytics(p_date DATE)
RETURNS TABLE (
    total_sales NUMERIC, 
    total_purchases NUMERIC, 
    receivables NUMERIC, 
    payables NUMERIC,
    net_profit NUMERIC,
    overdue_count INT
) AS $$
DECLARE 
    v_ar_id UUID;
    v_ap_id UUID;
    v_cogs_id UUID;
    v_expenses NUMERIC;
BEGIN
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
    SELECT id INTO v_cogs_id FROM public.accounts WHERE slug = 'cogs';

    -- Expenses (excluding COGS for pure operating profit calculation if needed, 
    -- but here we just want total expenses for the period)
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0) INTO v_expenses
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE a.account_type = 'expense' AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    RETURN QUERY SELECT 
        -- Sales Today
        (SELECT COALESCE(SUM(total_amount), 0) FROM sales WHERE sale_date = p_date),
        -- Purchases Today
        (SELECT COALESCE(SUM(total_amount), 0) FROM purchases WHERE purchase_date = p_date),
        -- Receivables (Total Dr - Cr in AR Account)
        (SELECT COALESCE(SUM(debit_amount - credit_amount), 0) FROM ledger_entries WHERE account_id = v_ar_id AND (is_reversed IS NULL OR is_reversed = false)),
        -- Payables (Total Cr - Dr in AP Account)
        (SELECT COALESCE(SUM(credit_amount - debit_amount), 0) FROM ledger_entries WHERE account_id = v_ap_id AND (is_reversed IS NULL OR is_reversed = false)),
        -- Net Profit (All Income - All Expense)
        (SELECT COALESCE(SUM(credit_amount - debit_amount), 0) FROM ledger_entries le JOIN accounts a ON le.account_id = a.id WHERE a.account_type = 'income' AND (le.is_reversed IS NULL OR le.is_reversed = false)) - 
        (SELECT COALESCE(SUM(debit_amount - credit_amount), 0) FROM ledger_entries le JOIN accounts a ON le.account_id = a.id WHERE a.account_type = 'expense' AND (le.is_reversed IS NULL OR le.is_reversed = false)),
        -- Overdue: Keep count 0 for now as it's complex to calc real-time without current_balance
        0::INT
    ;
END; $$ LANGUAGE plpgsql STABLE;

-- =================================================================
-- 3. SMART MUNSHI TRANSFER (PARTY-AWARE)
-- =================================================================

CREATE OR REPLACE FUNCTION public.post_munshi_voucher(
    p_from_account_id UUID,
    p_to_account_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE DEFAULT CURRENT_DATE
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_voucher_no TEXT;
    v_voucher_type TEXT := 'transfer';
    v_from_is_party BOOLEAN;
    v_to_is_party BOOLEAN;
    v_from_party_type TEXT;
    v_to_party_type TEXT;
    v_from_ctrl_id UUID;
    v_to_ctrl_id UUID;
BEGIN
    -- 1. Validation
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

    -- 2. Party Detection & Control Account Resolution
    SELECT EXISTS(SELECT 1 FROM public.parties WHERE id = p_from_account_id), type INTO v_from_is_party, v_from_party_type FROM public.parties WHERE id = p_from_account_id;
    SELECT EXISTS(SELECT 1 FROM public.parties WHERE id = p_to_account_id), type INTO v_to_is_party, v_to_party_type FROM public.parties WHERE id = p_to_account_id;

    -- Resolve FROM Control Account
    IF v_from_is_party THEN
        IF v_from_party_type = 'supplier' THEN
            SELECT id INTO v_from_ctrl_id FROM public.accounts WHERE slug = 'ap';
        ELSE
            SELECT id INTO v_from_ctrl_id FROM public.accounts WHERE slug = 'ar';
        END IF;
    ELSE
        v_from_ctrl_id := p_from_account_id;
    END IF;

    -- Resolve TO Control Account
    IF v_to_is_party THEN
        IF v_to_party_type = 'supplier' THEN
            SELECT id INTO v_to_ctrl_id FROM public.accounts WHERE slug = 'ap';
        ELSE
            SELECT id INTO v_to_ctrl_id FROM public.accounts WHERE slug = 'ar';
        END IF;
    ELSE
        v_to_ctrl_id := p_to_account_id;
    END IF;

    -- 3. Voucher No
    v_voucher_no := 'TRF-' || to_char(p_date, 'YYYYMMDD') || '-' || floor(random() * 10000)::text;

    -- 4. Post Ledger
    -- CREDIT Giver
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, v_voucher_type, p_date, v_from_ctrl_id, CASE WHEN v_from_is_party THEN p_from_account_id ELSE NULL END, 0, p_amount, p_narration, auth.uid());

    -- DEBIT Receiver
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, v_voucher_type, p_date, v_to_ctrl_id, CASE WHEN v_to_is_party THEN p_to_account_id ELSE NULL END, p_amount, 0, p_narration, auth.uid());

    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END;
$$;

COMMIT;

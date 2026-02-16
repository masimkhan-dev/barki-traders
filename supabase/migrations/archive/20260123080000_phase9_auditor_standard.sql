-- Phase 9: THE AUDITOR'S GOLD STANDARD (Final Architecture)
-- -----------------------------------------------------------------
-- 1. PURGE Ledger Pollution: Removing Qty/Rate from the Financial Ledger
-- 2. SMART REPORTING: Using Lateral Joins for Party Statements
-- 3. HISTORICAL VALUATION: Balance Sheet reconstructs stock based on date.
-- 4. CONTROL ACCOUNTS: Surfacing Receivables (1100) and Payables (2000).

BEGIN;

--------------------------------------------------------------------------------
-- 1. ARCHITECTURE CLEANUP
--------------------------------------------------------------------------------
ALTER TABLE public.ledger_entries DROP COLUMN IF EXISTS quantity;
ALTER TABLE public.ledger_entries DROP COLUMN IF EXISTS rate;


--------------------------------------------------------------------------------
-- 2. HISTORIC STOCK RECONSTRUCTION (The Inventory Truth)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_historical_stock_value(p_date DATE)
RETURNS NUMERIC AS $$
BEGIN
    -- Formula: Total Purchases Value - Total Sales Value (up to that date)
    -- This assumes a simple periodic inventory model for valuation.
    RETURN COALESCE(
        (SELECT SUM(quantity * rate_per_unit) FROM purchases WHERE purchase_date <= p_date), 0) -
        COALESCE((SELECT SUM(quantity * rate_per_unit) FROM sales WHERE sale_date <= p_date), 0);
END;
$$ LANGUAGE plpgsql STABLE;


--------------------------------------------------------------------------------
-- 3. SMART & SAFE PARTY STATEMENT (Option B: JOIN Based)
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_party_statement(UUID, DATE, DATE);

CREATE OR REPLACE FUNCTION public.get_party_statement(p_party_id UUID, p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    posting_date DATE, 
    voucher_no TEXT, 
    particulars TEXT, 
    quantity_display TEXT, 
    rate_display TEXT,     
    debit NUMERIC, 
    credit NUMERIC, 
    running_balance NUMERIC
) AS $$
DECLARE v_opening_balance NUMERIC := 0;
BEGIN
    -- Opening Balance Calculation
    SELECT COALESCE(p.opening_balance, 0) + COALESCE((
        SELECT SUM(le.debit_amount - le.credit_amount) 
        FROM ledger_entries le 
        WHERE le.party_id = p_party_id AND le.posting_date < p_start_date
    ), 0)
    INTO v_opening_balance 
    FROM parties p 
    WHERE p.id = p_party_id;

    -- Row 1: Opening Row
    RETURN QUERY SELECT 
        (p_start_date - INTERVAL '1 day')::DATE, 
        'OPENING'::TEXT, 
        'Opening Balance B/F'::TEXT, 
        '-'::TEXT, 
        '-'::TEXT, 
        ROUND(CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0.0 END, 2), 
        ROUND(CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0.0 END, 2), 
        ROUND(v_opening_balance, 2);

    -- Transaction Rows
    RETURN QUERY 
    SELECT 
        le.posting_date, 
        le.voucher_no, 
        (CASE 
            WHEN le.voucher_type = 'sale' THEN 'Fuel Sale'
            WHEN le.voucher_type = 'purchase' THEN 'Fuel Purchase'
            WHEN le.voucher_type = 'payment' THEN 'Payment/Receipt'
            ELSE le.voucher_type::TEXT
         END || ' - ' || COALESCE(le.narration, ''))::TEXT,
        COALESCE(items.qty_summary, '-') as quantity_display,
        COALESCE(items.rate_summary, '-') as rate_display,
        ROUND(le.debit_amount, 2), 
        ROUND(le.credit_amount, 2),
        ROUND((SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at, le.id) + v_opening_balance), 2)::NUMERIC
    FROM ledger_entries le
    LEFT JOIN LATERAL (
        -- Safely pull data from Sales
        SELECT 
            SUM(s.quantity)::TEXT || ' Ltr' as qty_summary,
            CASE WHEN COUNT(DISTINCT s.rate_per_unit) > 1 THEN 'VARIES' ELSE MAX(s.rate_per_unit)::TEXT END as rate_summary
        FROM sales s WHERE s.voucher_no = le.voucher_no AND le.voucher_type = 'sale'
        UNION ALL
        -- Safely pull data from Purchases
        SELECT 
            SUM(p.quantity)::TEXT || ' Ltr' as qty_summary,
            CASE WHEN COUNT(DISTINCT p.rate_per_unit) > 1 THEN 'VARIES' ELSE MAX(p.rate_per_unit)::TEXT END as rate_summary
        FROM purchases p WHERE p.voucher_no = le.voucher_no AND le.voucher_type = 'purchase'
        LIMIT 1
    ) items ON TRUE
    WHERE le.party_id = p_party_id 
      AND le.posting_date BETWEEN p_start_date AND p_end_date
    ORDER BY le.posting_date, le.created_at, le.id;
END;
$$ LANGUAGE plpgsql;


--------------------------------------------------------------------------------
-- 4. PROFESSIONAL FINANCIAL POSITION (Historical Reconstruction)
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS get_financial_position(DATE);

CREATE OR REPLACE FUNCTION get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE v_net_profit NUMERIC;
BEGIN
    -- Historical Profit Calculation
    SELECT COALESCE((
        SELECT SUM(le.credit_amount - le.debit_amount) 
        FROM accounts a 
        JOIN ledger_entries le ON le.account_id = a.id 
        WHERE a.account_type::TEXT ILIKE 'income' AND le.posting_date <= p_date
    ), 0)
    - COALESCE((
        SELECT SUM(le.debit_amount - le.credit_amount) 
        FROM accounts a 
        JOIN ledger_entries le ON le.account_id = a.id 
        WHERE a.account_type::TEXT ILIKE 'expense' AND le.posting_date <= p_date
    ), 0)
    INTO v_net_profit;

    RETURN QUERY
    -- A. ASSETS (Cash & Bank)
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT, SUM(le.debit_amount - le.credit_amount)
    FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
    WHERE le.posting_date <= p_date AND (a.account_type::TEXT ILIKE 'asset' OR a.code = '1100') AND a.code NOT IN ('1200')
    GROUP BY a.id, a.name HAVING SUM(le.debit_amount - le.credit_amount) != 0

    UNION ALL
    -- B. INVENTORY (The Historic Truth)
    SELECT 'ASSETS'::TEXT, 'Inventory'::TEXT, 'Fuel Stock (Historical Value)'::TEXT, get_historical_stock_value(p_date)
    WHERE get_historical_stock_value(p_date) != 0

    UNION ALL
    -- C. LIABILITIES (Including Payables 2000)
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
    WHERE le.posting_date <= p_date AND (a.account_type::TEXT ILIKE 'liability' OR a.code = '2000')
    GROUP BY a.id, a.name HAVING SUM(le.debit_amount - le.credit_amount) != 0

    UNION ALL
    -- D. EQUITY & CAPITAL
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name::TEXT, ABS(SUM(le.debit_amount - le.credit_amount))
    FROM accounts a JOIN ledger_entries le ON le.account_id = a.id 
    WHERE le.posting_date <= p_date AND a.account_type::TEXT ILIKE 'equity'
    GROUP BY a.id, a.name
    
    UNION ALL
    -- E. RETAINED EARNINGS (Accumulated Profit)
    SELECT 'EQUITY'::TEXT, 'Profit/Loss'::TEXT, 'Accumulated Net Profit/(Loss)'::TEXT, COALESCE(v_net_profit, 0);

END;
$$ LANGUAGE plpgsql;

COMMIT;

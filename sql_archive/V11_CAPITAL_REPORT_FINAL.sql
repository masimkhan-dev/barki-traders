-- V11 ULTIMATE EQUITY REPORT FIX
-- Purpose: Correct the Proprietor's Equity Statement to show accurate balances and NO technical drawings.
-- TARGET: get_owner_capital_report_v11 (Called by the UI)

DROP FUNCTION IF EXISTS public.get_owner_capital_report_v11(DATE, DATE);

CREATE OR REPLACE FUNCTION public.get_owner_capital_report_v11(p_start_date DATE, p_end_date DATE)
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
    -- 1. Identify valid Capital/Drawings accounts only
    -- EXCLUDE 'P&L Closing Adjustment' or 'NIL Adjustment' accounts from being grouped here
    SELECT array_agg(id) INTO v_capital_acc_ids 
    FROM public.accounts 
    WHERE (code = '3010' OR slug IN ('capital', 'owner-capital', 'drawings') OR name ILIKE '%Proprietor%')
      AND (name NOT ILIKE '%Closing Adjustment%' AND name NOT ILIKE '%NIL Adjustment%');

    -- 2. Opening Balance (Before the start date)
    -- We must exclude NIL Adjustments from the balance calculation too
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0) INTO v_opening_balance
    FROM public.ledger_entries le
    WHERE le.account_id = ANY(v_capital_acc_ids) 
      AND le.posting_date < p_start_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND le.narration NOT ILIKE '%NIL Adjustment%';

    -- 3. Return Transactions for the period
    RETURN QUERY
    WITH tx AS (
        SELECT 
            le.posting_date,
            le.voucher_no,
            le.narration,
            le.debit_amount,
            le.credit_amount,
            le.created_at,
            -- We only want to see the "Increase" side in this ledger view
            -- Technical "NIL" resets should be invisible in the Proprietor's statement
            SUM(CASE WHEN le.narration ILIKE '%NIL Adjustment%' THEN 0 ELSE (le.credit_amount - le.debit_amount) END) 
            OVER (ORDER BY le.posting_date, le.created_at) as period_running
        FROM public.ledger_entries le
        WHERE le.account_id = ANY(v_capital_acc_ids) 
          AND le.posting_date >= p_start_date 
          AND le.posting_date <= p_end_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
          -- EXPLICIT FILTER: Do not show the NIL recovery lines in the ledger view
          AND le.narration NOT ILIKE '%NIL Adjustment%'
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

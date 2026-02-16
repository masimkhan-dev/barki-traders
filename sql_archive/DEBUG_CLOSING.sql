-- DEBUG CLOSING CALCULATION
-- Purpose: See exactly what the closing function sees.

DO $$
DECLARE
    p_month_year TEXT := '2026-02';
    v_start_date DATE := (p_month_year || '-01')::DATE;
    v_end_date DATE := '2026-02-28';
    v_total_income NUMERIC;
    v_total_expense NUMERIC;
    v_net_profit NUMERIC;
BEGIN
    SELECT 
        COALESCE(SUM(CASE WHEN a.account_type = 'income' THEN (le.credit_amount - le.debit_amount) ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN a.account_type = 'expense' THEN (le.debit_amount - le.credit_amount) ELSE 0 END), 0)
    INTO v_total_income, v_total_expense
    FROM public.ledger_entries le 
    JOIN public.accounts a ON le.account_id = a.id
    WHERE le.posting_date >= v_start_date AND le.posting_date <= v_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
      AND le.narration NOT ILIKE '%P&L NIL Adjustment%';

    v_net_profit := v_total_income - v_total_expense;
    
    RAISE NOTICE 'Income: %, Expense: %, Net: %', v_total_income, v_total_expense, v_net_profit;
END $$;

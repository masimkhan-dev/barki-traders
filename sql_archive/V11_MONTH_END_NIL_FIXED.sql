-- V11 MONTH-END P&L CLOSING LOGIC (NIL Logic - FIXED)
-- Purpose: Transfer monthly net profit from P&L to Proprietor Capital.
-- FIX: Removed references to non-existent 'vouchers' table.

CREATE OR REPLACE FUNCTION execute_month_end_closing(
    p_month_year TEXT,      -- e.g. '2024-01'
    p_voucher_no TEXT,
    p_closing_date DATE,
    p_user_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_start_date DATE := (p_month_year || '-01')::DATE;
    v_end_date DATE := (date_trunc('month', v_start_date) + interval '1 month' - interval '1 day')::DATE;
    v_net_profit NUMERIC := 0;
    v_capital_acc_id UUID;
BEGIN
    -- 1. Calculate Net Profit for the period (Income - Expenses)
    WITH pnl_calc AS (
        SELECT 
            COALESCE(SUM(CASE WHEN a.account_type = 'income' THEN (le.credit_amount - le.debit_amount) ELSE 0 END), 0) as total_income,
            COALESCE(SUM(CASE WHEN a.account_type = 'expense' THEN (le.debit_amount - le.credit_amount) ELSE 0 END), 0) as total_expense
        FROM public.ledger_entries le
        JOIN public.accounts a ON le.account_id = a.id
        WHERE le.posting_date >= v_start_date AND le.posting_date <= v_end_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
          AND le.narration NOT ILIKE '%Month-End P&L Closing%'
    )
    SELECT total_income - total_expense INTO v_net_profit FROM pnl_calc;

    IF v_net_profit = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'No profit to transfer for this period.');
    END IF;

    -- 2. Identify Capital Account
    SELECT id INTO v_capital_acc_id FROM public.accounts WHERE slug IN ('capital', 'owner-capital') OR code = '3010' LIMIT 1;

    IF v_capital_acc_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Proprietor Capital account not found.');
    END IF;

    -- 3. Post Balanced Entries directly to ledger_entries
    -- Entry 1: The Capital Increase (Credit Capital for Profit)
    INSERT INTO public.ledger_entries (
        voucher_no,
        voucher_type,
        account_id,
        posting_date,
        credit_amount,
        debit_amount,
        narration,
        created_by
    ) VALUES (
        p_voucher_no,
        'journal',
        v_capital_acc_id,
        p_closing_date,
        CASE WHEN v_net_profit > 0 THEN v_net_profit ELSE 0 END,
        CASE WHEN v_net_profit < 0 THEN ABS(v_net_profit) ELSE 0 END,
        'Profit Transfer for ' || p_month_year || ' (Month-End P&L Closing)',
        p_user_id
    );

    -- Entry 2: The Offset (Debit Capital for Profit - Self-balancing audit line)
    -- This creates the NIL effect for P&L while keeping a record in Capital
    INSERT INTO public.ledger_entries (
        voucher_no,
        voucher_type,
        account_id,
        posting_date,
        credit_amount,
        debit_amount,
        narration,
        created_by
    ) VALUES (
        p_voucher_no,
        'journal',
        v_capital_acc_id,
        p_closing_date,
        CASE WHEN v_net_profit < 0 THEN ABS(v_net_profit) ELSE 0 END,
        CASE WHEN v_net_profit > 0 THEN v_net_profit ELSE 0 END,
        'P&L NIL Adjustment for ' || p_month_year || ' (Month-End P&L Closing)',
        p_user_id
    );

    RETURN jsonb_build_object('success', true, 'message', 'Month closing executed. Voucher: ' || p_voucher_no, 'profit', v_net_profit);
END; $$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER;

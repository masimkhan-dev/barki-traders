-- PHASE 4: PROFIT & LOSS STATEMENT (MUNSHI STYLE) - POLISHED
-- -----------------------------------------------------
-- This RPC generates a standard "Trading Account" P&L.
-- CRITICAL NOTE: Because we use Periodic Inventory, the User MUST provide
-- the Opening and Closing Stock Values manually (or estimated by UI).
-- Adds Expense Tracking and Rounding for robustness.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_pnl_statement(
    p_start_date DATE, 
    p_end_date DATE, 
    p_opening_stock_val NUMERIC DEFAULT 0, 
    p_closing_stock_val NUMERIC DEFAULT 0
)
RETURNS TABLE (
    row_order INT,
    section TEXT, 
    label TEXT, 
    amount NUMERIC, 
    is_header BOOLEAN,
    is_total BOOLEAN
) AS $$
DECLARE
    v_total_sales NUMERIC := 0;
    v_total_purchases NUMERIC := 0;
    v_total_expenses NUMERIC := 0;
    v_cogs NUMERIC := 0;
    v_gross_profit NUMERIC := 0;
    v_net_profit NUMERIC := 0;
BEGIN
    -- 1. CALCULATE REVENUE (Sales)
    -- Sum of Credits to Revenue Account (Party is NULL in strictly hardened ledger)
    SELECT COALESCE(SUM(credit_amount), 0)
    INTO v_total_sales
    FROM ledger_entries
    WHERE voucher_type = 'sale' 
      AND party_id IS NULL
      AND posting_date BETWEEN p_start_date AND p_end_date;

    -- 2. CALCULATE PURCHASES
    -- Sum of Debits to Expense/Asset Account (Party is NULL)
    SELECT COALESCE(SUM(debit_amount), 0)
    INTO v_total_purchases
    FROM ledger_entries
    WHERE voucher_type = 'purchase'
      AND party_id IS NULL
      AND posting_date BETWEEN p_start_date AND p_end_date;

    -- 2b. CALCULATE EXPENSES (For future 'expense' vouchers)
    -- Assumes 'expense' type vouchers exist or will exist
    SELECT COALESCE(SUM(debit_amount), 0)
    INTO v_total_expenses
    FROM ledger_entries
    WHERE voucher_type = 'expense'
      AND posting_date BETWEEN p_start_date AND p_end_date;

    -- 3. CALCULATE COGS
    -- Formula: Opening + Purchases - Closing
    v_cogs := p_opening_stock_val + v_total_purchases - p_closing_stock_val;

    -- 4. GROSS PROFIT
    v_gross_profit := v_total_sales - v_cogs;

    -- 5. NET PROFIT
    v_net_profit := v_gross_profit - v_total_expenses;

    -- 6. RETURN REPORT ROWS (With Rounding)
    
    -- REVENUE SECTION
    RETURN QUERY VALUES (1, 'REVENUE', 'Sales Revenue', ROUND(v_total_sales, 2), FALSE, FALSE);
    RETURN QUERY VALUES (2, 'REVENUE', 'Total Revenue', ROUND(v_total_sales, 2), FALSE, TRUE);

    -- COST OF GOODS SOLD SECTION
    RETURN QUERY VALUES (3, 'COGS', 'Opening Stock Value (Input)', ROUND(p_opening_stock_val, 2), FALSE, FALSE);
    RETURN QUERY VALUES (4, 'COGS', 'Add: Purchases', ROUND(v_total_purchases, 2), FALSE, FALSE);
    RETURN QUERY VALUES (5, 'COGS', 'Less: Closing Stock Value (Input)', ROUND(-p_closing_stock_val, 2), FALSE, FALSE);
    RETURN QUERY VALUES (6, 'COGS', 'Cost of Goods Sold', ROUND(v_cogs, 2), FALSE, TRUE);

    -- GROSS PROFIT
    RETURN QUERY VALUES (7, 'PROFIT', 'GROSS PROFIT', ROUND(v_gross_profit, 2), TRUE, TRUE);

    -- EXPENSES SECTION
    RETURN QUERY VALUES (8, 'EXPENSES', 'Direct/Indirect Expenses', ROUND(v_total_expenses, 2), FALSE, FALSE);

    -- NET PROFIT
    RETURN QUERY VALUES (9, 'PROFIT', 'NET PROFIT', ROUND(v_net_profit, 2), TRUE, TRUE);

END;
$$ LANGUAGE plpgsql;

COMMIT;

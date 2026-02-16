-- V11 P&L LOGIC (AUDIT STANDARD - NIL COMPATIBLE)
-- Strategy: Include ALL entries (including Month-End Closing) so that profit hits zero for closed periods.

DROP FUNCTION IF EXISTS get_profit_loss_v11(DATE, DATE);

CREATE OR REPLACE FUNCTION get_profit_loss_v11(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    section TEXT,
    account_name TEXT,
    amount NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        CASE 
            WHEN a.account_type = 'income' THEN 'Income'
            WHEN a.slug = 'cogs' OR a.name ILIKE '%Cost of Goods Sold%' OR a.code = '4100' THEN 'Direct Costs'
            ELSE 'Expenses'
        END as section,
        a.name,
        CASE 
            WHEN a.account_type = 'income' THEN SUM(le.credit_amount - le.debit_amount)
            ELSE SUM(le.debit_amount - le.credit_amount)
        END as amount
    FROM public.accounts a
    JOIN public.ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date BETWEEN p_start_date AND p_end_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name, a.account_type, a.slug, a.code;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


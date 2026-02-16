-- V11 DASHBOARD LOGIC (HARDENED - NO FILTER)
-- Purpose: Correct the "Ghost Rs 20" and match Account Statement accuracy perfectly.
-- Strategy: Use RAW summation (No is_reversed filter) so reversals cancel out naturally.

CREATE OR REPLACE FUNCTION get_dashboard_v11_3_analytics(p_date DATE)
RETURNS TABLE (
    sales_monthly NUMERIC, 
    purchases_monthly NUMERIC, 
    receivables NUMERIC, 
    payables NUMERIC,
    market_balance NUMERIC
) AS $$
DECLARE 
    v_month_start DATE := date_trunc('month', p_date);
BEGIN
    RETURN QUERY 
    WITH PartyBalances AS (
        -- CRITICAL: Includes Opening Balance + RAW Ledger entries.
        -- We REMOVED the is_reversed filter because original (+20) and reversal (-20) 
        -- must both stay in the math to reach 0.00.
        SELECT 
            p.id,
            (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) as balance
        FROM public.parties p
        LEFT JOIN public.ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
        GROUP BY p.id, p.opening_balance
    )
    SELECT 
        -- 1. Sales Total (Monthly)
        (SELECT COALESCE(SUM(total_amount), 0) FROM public.sales WHERE sale_date >= v_month_start AND sale_date <= p_date),
        
        -- 2. Purchases Total (Monthly)
        (SELECT COALESCE(SUM(total_amount), 0) FROM public.purchases WHERE purchase_date >= v_month_start AND purchase_date <= p_date),
        
        -- 3. Total Receivables (Lena) - The sum of all people who owe the station money.
        (SELECT COALESCE(SUM(balance), 0) FROM PartyBalances WHERE balance > 0) as receivables,
        
        -- 4. Total Payables (Dena) - The sum of all money the station owes to suppliers.
        (SELECT ABS(COALESCE(SUM(balance), 0)) FROM PartyBalances WHERE balance < 0) as payables,

        -- 5. Net Market Position (Receivable - Payable)
        (SELECT COALESCE(SUM(balance), 0) FROM PartyBalances) as market_balance
    ;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

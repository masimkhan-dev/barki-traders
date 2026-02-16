-- =================================================================
-- FIX DASHBOARD ANALYTICS (DISCREPANCY REMOVAL)
-- Purpose: Remove the reversal filtering that caused Rs 30 vs Rs 10 
--          mismatch on the dashboard.
-- =================================================================

BEGIN;

-- First drop the existing function to avoid "return type mismatch" errors
DROP FUNCTION IF EXISTS get_dashboard_v10_analytics(date);

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
BEGIN
    -- Find AR/AP accounts by slug
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug IN ('ar', 'accounts-receivable') LIMIT 1;
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug IN ('ap', 'accounts-payable') LIMIT 1;

    RETURN QUERY SELECT 
        -- Sales Today (Direct from Sales Table)
        (SELECT COALESCE(SUM(total_amount), 0) FROM public.sales WHERE sale_date = p_date),
        
        -- Purchases Today (Direct from Purchases Table)
        (SELECT COALESCE(SUM(total_amount), 0) FROM public.purchases WHERE purchase_date = p_date),
        
        -- Receivables (NO FILTERING for reversals - let them cancel naturally)
        (
            SELECT COALESCE(SUM(debit_amount - credit_amount), 0) 
            FROM public.ledger_entries 
            WHERE (account_id = v_ar_id AND v_ar_id IS NOT NULL) 
               OR (party_id IN (SELECT id FROM parties WHERE type IN ('customer', 'both')))
        ) as receivables,
        
        -- Payables (NO FILTERING for reversals)
        (
            SELECT ABS(COALESCE(SUM(credit_amount - debit_amount), 0)) 
            FROM public.ledger_entries 
            WHERE (account_id = v_ap_id AND v_ap_id IS NOT NULL)
               OR (party_id IN (SELECT id FROM parties WHERE type IN ('supplier', 'both')))
        ) as payables,
        
        -- Net Profit (All Income - All Expenses, No filtering)
        (
            (SELECT COALESCE(SUM(credit_amount - debit_amount), 0) FROM public.ledger_entries le JOIN public.accounts a ON le.account_id = a.id WHERE a.account_type = 'income') - 
            (SELECT COALESCE(SUM(debit_amount - credit_amount), 0) FROM public.ledger_entries le JOIN public.accounts a ON le.account_id = a.id WHERE a.account_type = 'expense')
        ) as net_profit,
        
        -- Overdue (Placeholder)
        0::INT
    ;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMIT;

-- VERIFICATION
-- SELECT * FROM get_dashboard_v10_analytics(CURRENT_DATE);

-- =================================================================
-- FIX DASHBOARD & STOCK ANALYTICS
-- =================================================================

BEGIN;

-- 1. RESTORE DASHBOARD ANALYTICS FUNCTION
-- Ensure it correctly calculates totals and handles missing slugs
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
    -- Attempt to find AR/AP accounts, handled safely
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug IN ('ar', 'accounts-receivable') LIMIT 1;
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug IN ('ap', 'accounts-payable') LIMIT 1;

    RETURN QUERY SELECT 
        -- Sales Today (Direct from Sales Table)
        (SELECT COALESCE(SUM(total_amount), 0) FROM public.sales WHERE sale_date = p_date),
        
        -- Purchases Today (Direct from Purchases Table)
        (SELECT COALESCE(SUM(total_amount), 0) FROM public.purchases WHERE purchase_date = p_date),
        
        -- Receivables (From Ledger using Party logic + AR Control)
        (
            SELECT COALESCE(SUM(debit_amount - credit_amount), 0) 
            FROM public.ledger_entries 
            WHERE (account_id = v_ar_id AND v_ar_id IS NOT NULL) 
               OR (party_id IN (SELECT id FROM parties WHERE type IN ('customer', 'both')))
               AND (is_reversed IS NULL OR is_reversed = false)
        ) as receivables,
        
        -- Payables (From Ledger using Party logic + AP Control)
        (
            SELECT ABS(COALESCE(SUM(credit_amount - debit_amount), 0)) 
            FROM public.ledger_entries 
            WHERE (account_id = v_ap_id AND v_ap_id IS NOT NULL)
               OR (party_id IN (SELECT id FROM parties WHERE type IN ('supplier', 'both')))
               AND (is_reversed IS NULL OR is_reversed = false)
        ) as payables,
        
        -- Net Profit (All Income - All Expenses)
        (
            (SELECT COALESCE(SUM(credit_amount - debit_amount), 0) FROM public.ledger_entries le JOIN public.accounts a ON le.account_id = a.id WHERE a.account_type = 'income' AND (le.is_reversed IS NULL OR le.is_reversed = false)) - 
            (SELECT COALESCE(SUM(debit_amount - credit_amount), 0) FROM public.ledger_entries le JOIN public.accounts a ON le.account_id = a.id WHERE a.account_type = 'expense' AND (le.is_reversed IS NULL OR le.is_reversed = false))
        ) as net_profit,
        
        -- Overdue (Placeholder)
        0::INT
    ;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


-- 2. RESTORE STOCK MOVEMENT FUNCTION
-- Ensure it calculates accurately based on all time history
CREATE OR REPLACE FUNCTION public.get_stock_movement(
    p_start_date DATE DEFAULT CURRENT_DATE - INTERVAL '30 days',
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    fuel_name TEXT,
    opening_stock NUMERIC,
    purchased NUMERIC,
    sold NUMERIC,
    closing_stock NUMERIC
) 
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ft.name::TEXT,
        
        -- Opening Stock
        (
            COALESCE((SELECT SUM(quantity) FROM public.purchases WHERE fuel_type_id = ft.id AND purchase_date < p_start_date), 0) - 
            COALESCE((SELECT SUM(quantity) FROM public.sales WHERE fuel_type_id = ft.id AND sale_date < p_start_date), 0)
        ) as opening_stock,
        
        -- Purchased
        COALESCE((SELECT SUM(quantity) FROM public.purchases WHERE fuel_type_id = ft.id AND purchase_date BETWEEN p_start_date AND p_end_date), 0) as purchased,
        
        -- Sold
        COALESCE((SELECT SUM(quantity) FROM public.sales WHERE fuel_type_id = ft.id AND sale_date BETWEEN p_start_date AND p_end_date), 0) as sold,
        
        -- Closing Stock (Cumulative)
        (
            COALESCE((SELECT SUM(quantity) FROM public.purchases WHERE fuel_type_id = ft.id AND purchase_date <= p_end_date), 0) - 
            COALESCE((SELECT SUM(quantity) FROM public.sales WHERE fuel_type_id = ft.id AND sale_date <= p_end_date), 0)
        ) as closing_stock
        
    FROM public.fuel_types ft
    WHERE ft.is_active = true
    ORDER BY ft.name;
END;
$$;

COMMIT;

-- 3. DIAGNOSTIC QUERY (Run this separately to check data)
-- SELECT count(*) as sales_count FROM public.sales;
-- SELECT count(*) as purchases_count FROM public.purchases;

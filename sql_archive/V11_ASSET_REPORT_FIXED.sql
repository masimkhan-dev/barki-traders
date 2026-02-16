-- FINAL V11 ASSET REPORT ALIAS
-- Purpose: Ensures the UI correctly calls the robust fixed asset logic.

DROP FUNCTION IF EXISTS public.get_fixed_assets_report_v11();

CREATE OR REPLACE FUNCTION public.get_fixed_assets_report_v11()
RETURNS TABLE (
    account_name TEXT,
    original_value NUMERIC,
    depreciation NUMERIC,
    net_value NUMERIC
) AS $$
BEGIN
    RETURN QUERY 
    SELECT 
        a.name as account_name,
        COALESCE(SUM(le.debit_amount), 0) as original_value,
        COALESCE(SUM(le.credit_amount), 0) as depreciation,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as net_value
    FROM public.accounts a
    JOIN public.ledger_entries le ON a.id = le.account_id
    WHERE a.account_type = 'asset' 
      AND (
        a.sub_category ILIKE '%Fixed%' 
        OR a.slug ILIKE '%fixed-asset%' 
        OR a.name ILIKE '%Furniture%' 
        OR a.name ILIKE '%Building%' 
        OR a.name ILIKE '%Vehicle%'
        OR a.name ILIKE '%laptop%'
        OR a.name ILIKE '%chairs%'
      )
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

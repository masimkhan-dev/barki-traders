
-- FIX ASSET REPORTING VISIBILITY (NULL SLUG FIX)
-- Purpose: Fix the SQL query to handle NULL slugs correctly.

CREATE OR REPLACE FUNCTION get_fixed_assets_report()
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
        COALESCE(SUM(CASE WHEN le.debit_amount > 0 THEN le.debit_amount ELSE 0 END), 0) as original_value,
        COALESCE(SUM(CASE WHEN le.credit_amount > 0 THEN le.credit_amount ELSE 0 END), 0) as depreciation,
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as net_value
    FROM public.accounts a
    JOIN public.ledger_entries le ON a.id = le.account_id
    WHERE a.account_type = 'asset' 
      AND (
          a.sub_category IN ('Equipment', 'Vehicle', 'Furniture', 'Machinery', 'Building') 
          OR a.sub_category ILIKE '%Fixed%' 
          OR a.slug ILIKE '%fixed-asset%'   
          OR a.name ILIKE '%Fixed Asset%'   
          OR a.name ILIKE '%Furniture%'     
          OR a.name ILIKE '%Building%'
          OR a.name ILIKE '%Vehicle%'
          OR a.name ILIKE '%Machinery%'
          OR a.name ILIKE '%Equipment%'
      )
      -- CRITICAL FIX: Handle NULL slug
      AND (a.slug IS NULL OR a.slug NOT IN ('cash', 'bank', 'inventory', 'cogs', 'sales_revenue', 'accounts_receivable', 'accounts_payable'))
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

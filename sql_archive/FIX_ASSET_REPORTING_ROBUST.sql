
-- FIX ASSET REPORTING (ROBUST VERSION)
-- Purpose: Handle NULL slugs, include zero-balance assets, and ensure correct aggregation.

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
        a.name AS account_name,
        -- Debits (Purchase Cost)
        COALESCE(SUM(CASE WHEN le.debit_amount > 0 THEN le.debit_amount ELSE 0 END), 0) AS original_value,
        -- Credits (Depreciation / Sale)
        COALESCE(SUM(CASE WHEN le.credit_amount > 0 THEN le.credit_amount ELSE 0 END), 0) AS depreciation,
        -- Net Book Value
        COALESCE(SUM(COALESCE(le.debit_amount,0) - COALESCE(le.credit_amount,0)), 0) AS net_value
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le ON a.id = le.account_id
         AND (le.is_reversed IS NULL OR le.is_reversed = false)
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
      -- CRITICAL FIX: Handle NULL slug safely
      AND (a.slug IS NULL OR a.slug NOT IN ('cash', 'bank', 'inventory', 'cogs', 'sales_revenue', 'accounts_receivable', 'accounts_payable'))
    GROUP BY a.id, a.name
    ORDER BY a.name;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

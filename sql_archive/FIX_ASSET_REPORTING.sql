
-- FIX ASSET REPORTING VISIBILITY
-- Purpose: Update the `get_fixed_assets_report` function to include all legitimate Fixed Asset categories (Machinery, Equipment, etc.) that were previously ignored.

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
        -- Debits increase asset value (Purchase)
        COALESCE(SUM(CASE WHEN le.debit_amount > 0 THEN le.debit_amount ELSE 0 END), 0) as original_value,
        -- Credits decrease asset value (Depreciation/Sale)
        COALESCE(SUM(CASE WHEN le.credit_amount > 0 THEN le.credit_amount ELSE 0 END), 0) as depreciation,
        -- Net Book Value
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as net_value
    FROM public.accounts a
    JOIN public.ledger_entries le ON a.id = le.account_id
    WHERE a.account_type = 'asset' 
      -- FIX: Expanded logic to capture all fixed asset types
      AND (
          a.sub_category IN ('Equipment', 'Vehicle', 'Furniture', 'Machinery', 'Building') -- Explicit Categories
          OR a.sub_category ILIKE '%Fixed%' -- Generic Fixed Assets
          OR a.slug ILIKE '%fixed-asset%'   -- Legacy Slug Pattern
          OR a.name ILIKE '%Fixed Asset%'   -- Legacy Name Pattern
          OR a.name ILIKE '%Furniture%'     -- Fallback Name Pattern
          OR a.name ILIKE '%Building%'
          OR a.name ILIKE '%Vehicle%'
          OR a.name ILIKE '%Machinery%'
          OR a.name ILIKE '%Equipment%'
      )
      -- SAFETY: Ensure we don't accidentally pick up Current Assets if they have weird names
      AND a.slug NOT IN ('cash', 'bank', 'inventory', 'cogs', 'sales_revenue', 'accounts_receivable', 'accounts_payable')
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.id, a.name;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

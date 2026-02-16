
-- DIAGNOSE REPORT VISIBILITY (TABLE FORMAT)
-- Purpose: Show counts and checks directly in a result table.

SELECT 
    'Capital Ledger Count' as check_name,
    count(*) as count_result,
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'FAIL' END as status
FROM ledger_entries le
JOIN accounts a ON le.account_id = a.id
WHERE (a.slug = 'owner-capital' OR a.name ILIKE '%Capital%')

UNION ALL

SELECT 
    'Laptop Asset Count',
    count(*),
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'FAIL' END
FROM ledger_entries le
JOIN accounts a ON le.account_id = a.id
WHERE a.name ILIKE '%laptop%'

UNION ALL

SELECT
    'Fixed Asset Logic Check',
    count(*),
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'FAIL (Logic is Broken)' END
FROM public.accounts a
JOIN public.ledger_entries le ON a.id = le.account_id
WHERE a.account_type = 'asset' 
  AND (
      a.sub_category IN ('Equipment', 'Vehicle', 'Furniture', 'Machinery', 'Building') 
      OR a.sub_category ILIKE '%Fixed%' 
      OR a.name ILIKE '%Fixed Asset%'
      OR a.name ILIKE '%Furniture%'
      OR a.name ILIKE '%Building%'
      OR a.name ILIKE '%Vehicle%'
      OR a.name ILIKE '%Machinery%'
  )
  AND a.slug NOT IN ('cash', 'bank', 'inventory', 'cogs', 'sales_revenue', 'accounts_receivable', 'accounts_payable')
  AND (le.is_reversed IS NULL OR le.is_reversed = false);

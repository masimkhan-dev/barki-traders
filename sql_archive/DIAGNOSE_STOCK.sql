-- DIAGNOSE STOCK MOVEMENT
SELECT 'Fuel Types Count' as label, count(*) as val FROM public.fuel_types
UNION ALL
SELECT 'Active Fuel Types' as label, count(*) as val FROM public.fuel_types WHERE is_active = true
UNION ALL
SELECT 'Inventory Records' as label, count(*) as val FROM public.inventory
UNION ALL
SELECT 'Sales Records' as label, count(*) as val FROM public.sales
UNION ALL
SELECT 'Purchase Records' as label, count(*) as val FROM public.purchases;

-- Check if fuel_type_id in sales/purchases matches fuel_types table
SELECT 'Sales with invalid fuel_type' as label, count(*) as val 
FROM public.sales s 
LEFT JOIN public.fuel_types ft ON s.fuel_type_id = ft.id 
WHERE ft.id IS NULL;

SELECT 'Purchases with invalid fuel_type' as label, count(*) as val 
FROM public.purchases p 
LEFT JOIN public.fuel_types ft ON p.fuel_type_id = ft.id 
WHERE ft.id IS NULL;

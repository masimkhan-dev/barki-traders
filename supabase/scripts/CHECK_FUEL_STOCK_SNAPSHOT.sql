-- Run in Supabase SQL Editor (change voucher at bottom if needed)
-- Compares: purchases sum, sales sum, computed stock, inventory cache, drift

-- 1) Per-fuel stock audit (what Stock Ledger UI uses)
SELECT
    ft.name AS fuel,
    ft.unit,
    COALESCE(p.total_in, 0) AS total_purchases,
    COALESCE(s.total_out, 0) AS total_sales,
    COALESCE(p.total_in, 0) - COALESCE(s.total_out, 0) AS computed_stock,
    COALESCE(i.quantity, 0) AS inventory_cache,
    COALESCE(p.total_in, 0) - COALESCE(s.total_out, 0) - COALESCE(i.quantity, 0) AS drift,
    CASE
        WHEN abs(COALESCE(p.total_in, 0) - COALESCE(s.total_out, 0) - COALESCE(i.quantity, 0)) < 0.001
        THEN 'OK'
        ELSE 'MISMATCH'
    END AS status,
    i.last_updated AS inventory_updated_at
FROM public.fuel_types ft
LEFT JOIN (
    SELECT fuel_type_id, SUM(quantity) AS total_in
    FROM public.purchases
    GROUP BY fuel_type_id
) p ON p.fuel_type_id = ft.id
LEFT JOIN (
    SELECT fuel_type_id, SUM(quantity) AS total_out
    FROM public.sales
    GROUP BY fuel_type_id
) s ON s.fuel_type_id = ft.id
LEFT JOIN public.inventory i ON i.fuel_type_id = ft.id
WHERE ft.is_active = true
ORDER BY ft.name;

-- 2) Last voucher check — change PUR-20260523-001 if needed
SELECT 'purchases' AS source, voucher_no, purchase_date AS tx_date, quantity, rate_per_unit, total_amount, fuel_type_id, party_id
FROM public.purchases
WHERE voucher_no = 'PUR-20260523-001';

SELECT 'ledger' AS source, voucher_no, posting_date, debit_amount, credit_amount, narration
FROM public.ledger_entries
WHERE voucher_no = 'PUR-20260523-001'
ORDER BY debit_amount DESC;

-- 3) Optional: repair inventory (only if migration 20260523110000 applied)
-- SELECT public.repair_inventory_from_transactions();

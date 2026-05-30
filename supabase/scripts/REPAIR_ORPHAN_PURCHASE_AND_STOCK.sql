-- =============================================================================
-- REPAIR: ledger-only PUR vouchers + inventory drift
-- Run in Supabase SQL Editor (one block at a time)
-- =============================================================================

-- A) Orphan vouchers: ledger exists, purchases row missing
SELECT le.voucher_no,
       MAX(le.posting_date) AS posting_date,
       MAX(CASE WHEN le.debit_amount > 0 THEN le.debit_amount END) AS inventory_debit,
       MAX(CASE WHEN le.credit_amount > 0 THEN le.party_id END) AS party_id
FROM public.ledger_entries le
WHERE le.voucher_no LIKE 'PUR-%'
  AND NOT EXISTS (
      SELECT 1 FROM public.purchases p WHERE p.voucher_no = le.voucher_no
  )
GROUP BY le.voucher_no
ORDER BY le.voucher_no;

-- -----------------------------------------------------------------------------
-- B) Backfill PUR-20260523-001  (EDIT qty / rate / fuel before running)
--    From your ledger: total = 400, narration "test 20 400" → qty 20, rate 20
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_fuel_id uuid;
    v_party_id uuid;
    v_voucher text := 'PUR-20260523-001';
    v_qty numeric := 20;          -- <<< change if needed
    v_rate numeric := 20;         -- <<< change if needed
    v_total numeric := 400;       -- must equal qty * rate
    v_date date := '2026-05-23';
BEGIN
    SELECT id INTO v_fuel_id FROM public.fuel_types WHERE lower(name) LIKE '%diesel%' LIMIT 1;
    -- For petrol use: WHERE lower(name) LIKE '%petrol%'

    SELECT party_id INTO v_party_id
    FROM public.ledger_entries
    WHERE voucher_no = v_voucher AND credit_amount > 0
    LIMIT 1;

    IF v_fuel_id IS NULL THEN
        RAISE EXCEPTION 'Fuel type not found — set v_fuel_id manually.';
    END IF;
    IF v_party_id IS NULL THEN
        RAISE EXCEPTION 'Party not found on ledger credit line.';
    END IF;
    IF abs(v_total - round(v_qty * v_rate, 2)) > 0.01 THEN
        RAISE EXCEPTION 'total must equal qty * rate';
    END IF;

    IF EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = v_voucher) THEN
        RAISE NOTICE 'Purchase row already exists for % — use edit in app instead.', v_voucher;
    ELSE
        INSERT INTO public.purchases (
            voucher_no, purchase_date, party_id, fuel_type_id,
            quantity, rate_per_unit, total_amount,
            is_paid_now, payment_method, notes, created_by
        )
        VALUES (
            v_voucher, v_date, v_party_id, v_fuel_id,
            v_qty, v_rate, v_total,
            false, 'Cash', 'Backfill from ledger', auth.uid()
        );
        RAISE NOTICE 'Inserted purchase row for %', v_voucher;
    END IF;
END $$;

-- C) Reconcile ALL fuel inventory from purchases − sales
--    (If RPC missing, run migration 20260523110000 first, OR use inline UPDATE below)
SELECT public.repair_inventory_from_transactions();

/*
-- C-alt) Inline repair if RPC not deployed yet:
UPDATE public.inventory i
SET quantity = sub.qty, last_updated = now()
FROM (
    SELECT ft.id AS fuel_type_id,
           GREATEST(COALESCE(p.t, 0) - COALESCE(s.t, 0), 0) AS qty
    FROM public.fuel_types ft
    LEFT JOIN (SELECT fuel_type_id, SUM(quantity) t FROM public.purchases GROUP BY 1) p ON p.fuel_type_id = ft.id
    LEFT JOIN (SELECT fuel_type_id, SUM(quantity) t FROM public.sales GROUP BY 1) s ON s.fuel_type_id = ft.id
) sub
WHERE i.fuel_type_id = sub.fuel_type_id;
*/

-- D) Verify (same as CHECK_FUEL_STOCK_SNAPSHOT query 1)
SELECT
    ft.name AS fuel,
    COALESCE(p.total_in, 0) - COALESCE(s.total_out, 0) AS computed_stock,
    COALESCE(i.quantity, 0) AS inventory_cache,
    COALESCE(p.total_in, 0) - COALESCE(s.total_out, 0) - COALESCE(i.quantity, 0) AS drift,
    CASE WHEN abs(COALESCE(p.total_in, 0) - COALESCE(s.total_out, 0) - COALESCE(i.quantity, 0)) < 0.001
         THEN 'OK' ELSE 'MISMATCH' END AS status
FROM public.fuel_types ft
LEFT JOIN (SELECT fuel_type_id, SUM(quantity) AS total_in FROM public.purchases GROUP BY 1) p ON p.fuel_type_id = ft.id
LEFT JOIN (SELECT fuel_type_id, SUM(quantity) AS total_out FROM public.sales GROUP BY 1) s ON s.fuel_type_id = ft.id
LEFT JOIN public.inventory i ON i.fuel_type_id = ft.id
WHERE ft.is_active = true
ORDER BY ft.name;

-- E) Confirm voucher now has purchases row
SELECT * FROM public.purchases WHERE voucher_no = 'PUR-20260523-001';

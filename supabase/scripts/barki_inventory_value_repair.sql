-- Barki live-data repair for current inventory valuation.
--
-- Preconditions verified in this thread:
-- - Solvent opening stock is 0 L.
-- - Solvent purchases total 13,000 L / Rs 4,476,000.
-- - Correct Solvent WAC = Rs 344.307692..., stored as 344.31 because
--   inventory.avg_cost is NUMERIC(15,2).
-- - Petrol current stock/value is accepted from inventory table.
--
-- Run only after a database backup. This script is intentionally idempotent:
-- it refuses to post the adjustment voucher twice.

BEGIN;

-- 1) Stop future AVCO corruption. This mirrors migration 09.
CREATE OR REPLACE FUNCTION public.apply_avco_on_purchase(
  p_fuel_type_id UUID,
  p_quantity NUMERIC,
  p_rate NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_qty_after NUMERIC := 0;
  v_old_qty NUMERIC := 0;
  v_old_cost NUMERIC := 0;
  v_new_cost NUMERIC := 0;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'AVCO ERROR: Purchase quantity must be positive.';
  END IF;

  IF p_rate < 0 THEN
    RAISE EXCEPTION 'AVCO ERROR: Purchase rate cannot be negative.';
  END IF;

  SELECT COALESCE(quantity, 0), COALESCE(avg_cost, 0)
  INTO v_qty_after, v_old_cost
  FROM public.inventory
  WHERE fuel_type_id = p_fuel_type_id
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
    VALUES (p_fuel_type_id, p_quantity, p_rate, now())
    ON CONFLICT (fuel_type_id) DO UPDATE
    SET avg_cost = EXCLUDED.avg_cost,
        last_updated = now();
    RETURN;
  END IF;

  v_old_qty := GREATEST(v_qty_after - p_quantity, 0);

  IF v_qty_after > 0 THEN
    v_new_cost := ((v_old_qty * v_old_cost) + (p_quantity * p_rate)) / v_qty_after;
  ELSE
    v_new_cost := p_rate;
  END IF;

  UPDATE public.inventory
  SET avg_cost = v_new_cost,
      last_updated = now()
  WHERE fuel_type_id = p_fuel_type_id;
END;
$$;

-- 2) Correct Solvent avg cost from actual purchase entries.
UPDATE public.inventory i
SET avg_cost = 344.31,
    last_updated = now()
FROM public.fuel_types ft
WHERE ft.id = i.fuel_type_id
  AND ft.name = 'Solvent'
  AND i.quantity = 5000.00;

-- 3) Move sold-stock value that is still stuck in Inventory Control to COGS.
-- Target inventory value after step 2:
--   Petrol  = 1,458 L * 367.56 = 535,902.48
--   Solvent = 5,000 L * 344.31 = 1,721,550.00
--   Total   = 2,257,452.48
-- Current ledger Inventory Control before this repair was Rs 3,306,236.50.
-- Adjustment = 3,306,236.50 - 2,257,452.48 = Rs 1,048,784.02.
DO $$
DECLARE
  v_voucher_no TEXT := 'ADJ-INV-WAC-20260611';
  v_inventory_id UUID;
  v_cogs_id UUID;
  v_adjustment NUMERIC := 1048784.02;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.ledger_entries
    WHERE voucher_no = v_voucher_no
  ) THEN
    RAISE EXCEPTION 'Inventory WAC adjustment voucher % already exists.', v_voucher_no;
  END IF;

  SELECT id INTO v_inventory_id
  FROM public.accounts
  WHERE slug = 'inventory' OR code = '1200'
  ORDER BY CASE WHEN slug = 'inventory' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT id INTO v_cogs_id
  FROM public.accounts
  WHERE slug = 'cogs' OR code = '4100'
  ORDER BY CASE WHEN slug = 'cogs' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_inventory_id IS NULL OR v_cogs_id IS NULL THEN
    RAISE EXCEPTION 'Missing inventory or COGS account.';
  END IF;

  INSERT INTO public.ledger_entries (
    voucher_no,
    voucher_type,
    posting_date,
    account_id,
    party_id,
    debit_amount,
    credit_amount,
    narration,
    quantity,
    rate,
    created_by
  )
  VALUES
    (
      v_voucher_no,
      'adjustment',
      DATE '2026-06-11',
      v_cogs_id,
      NULL,
      v_adjustment,
      0,
      'Inventory valuation repair: move sold stock cost to COGS after AVCO audit',
      0,
      0,
      auth.uid()
    ),
    (
      v_voucher_no,
      'adjustment',
      DATE '2026-06-11',
      v_inventory_id,
      NULL,
      0,
      v_adjustment,
      'Inventory valuation repair: reduce Inventory Control to current stock value',
      0,
      0,
      auth.uid()
    );
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Verification after COMMIT:
-- SELECT ft.name, i.quantity, i.avg_cost, ROUND(i.quantity * i.avg_cost, 2) AS value
-- FROM public.inventory i
-- JOIN public.fuel_types ft ON ft.id = i.fuel_type_id
-- ORDER BY ft.name;
--
-- SELECT ROUND(SUM(le.debit_amount - le.credit_amount), 2) AS ledger_inventory_value
-- FROM public.ledger_entries le
-- JOIN public.accounts a ON a.id = le.account_id
-- WHERE (a.slug = 'inventory' OR a.code = '1200')
--   AND COALESCE(le.is_reversed, false) = false
--   AND le.voucher_no NOT LIKE 'REV-%';

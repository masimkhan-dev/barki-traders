-- Fix AVCO double-counting caused by stock quantity being increased before avg_cost calculation.
-- Also repairs existing sale COGS / inventory-credit ledger lines from purchase WAC history.

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

  SELECT COALESCE(quantity, 0), COALESCE(avg_cost, 0)
  INTO v_qty_after, v_old_cost
  FROM public.inventory
  WHERE fuel_type_id = p_fuel_type_id
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
    VALUES (p_fuel_type_id, p_quantity, p_rate, now())
    ON CONFLICT (fuel_type_id) DO UPDATE
    SET avg_cost = p_rate,
        last_updated = now();
    RETURN;
  END IF;

  -- update_stock_quantity(..., 'IN') runs before this function, so remove the current
  -- purchase quantity to recover the true old quantity for weighted average cost.
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

CREATE OR REPLACE FUNCTION public.repair_inventory_gl_from_wac()
RETURNS TABLE(fuel_type_id UUID, fuel_name TEXT, sales_repaired INTEGER, final_qty NUMERIC, final_avg_cost NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fuel RECORD;
  v_tx RECORD;
  v_inventory_id UUID;
  v_cogs_id UUID;
  v_qty NUMERIC;
  v_avg NUMERIC;
  v_cogs NUMERIC;
  v_repaired INTEGER;
BEGIN
  SELECT id INTO v_inventory_id FROM public.accounts WHERE slug = 'inventory';
  IF v_inventory_id IS NULL THEN SELECT id INTO v_inventory_id FROM public.accounts WHERE code = '1200'; END IF;

  SELECT id INTO v_cogs_id FROM public.accounts WHERE slug = 'cogs';
  IF v_cogs_id IS NULL THEN SELECT id INTO v_cogs_id FROM public.accounts WHERE code = '4100'; END IF;

  IF v_inventory_id IS NULL OR v_cogs_id IS NULL THEN
    RAISE EXCEPTION 'Missing inventory or COGS account.';
  END IF;

  PERFORM set_config('my.audit_bypass', 'on', true);

  FOR v_fuel IN SELECT id, name FROM public.fuel_types LOOP
    v_qty := 0;
    v_avg := 0;
    v_repaired := 0;

    FOR v_tx IN
      SELECT 'purchase'::TEXT AS tx_type, voucher_no, purchase_date AS tx_date, created_at,
             quantity, rate_per_unit, total_amount
      FROM public.purchases
      WHERE public.purchases.fuel_type_id = v_fuel.id
        AND COALESCE(is_reversed, false) = false

      UNION ALL

      SELECT 'sale'::TEXT AS tx_type, voucher_no, sale_date AS tx_date, created_at,
             quantity, rate_per_unit, total_amount
      FROM public.sales
      WHERE public.sales.fuel_type_id = v_fuel.id
        AND COALESCE(is_reversed, false) = false

      ORDER BY tx_date, created_at, voucher_no
    LOOP
      IF v_tx.tx_type = 'purchase' THEN
        IF (v_qty + v_tx.quantity) > 0 THEN
          v_avg := ((v_qty * v_avg) + v_tx.total_amount) / (v_qty + v_tx.quantity);
        ELSE
          v_avg := v_tx.rate_per_unit;
        END IF;
        v_qty := v_qty + v_tx.quantity;
      ELSE
        v_cogs := ROUND(v_tx.quantity * v_avg, 2);

        UPDATE public.ledger_entries
        SET debit_amount = v_cogs,
            credit_amount = 0
        WHERE voucher_no = v_tx.voucher_no
          AND account_id = v_cogs_id
          AND COALESCE(is_reversed, false) = false;

        UPDATE public.ledger_entries
        SET debit_amount = 0,
            credit_amount = v_cogs
        WHERE voucher_no = v_tx.voucher_no
          AND account_id = v_inventory_id
          AND COALESCE(is_reversed, false) = false;

        v_qty := v_qty - v_tx.quantity;
        v_repaired := v_repaired + 1;
      END IF;
    END LOOP;

    UPDATE public.inventory
    SET quantity = v_qty,
        avg_cost = CASE WHEN v_qty > 0 THEN v_avg ELSE 0 END,
        last_updated = now()
    WHERE public.inventory.fuel_type_id = v_fuel.id;

    fuel_type_id := v_fuel.id;
    fuel_name := v_fuel.name;
    sales_repaired := v_repaired;
    final_qty := v_qty;
    final_avg_cost := CASE WHEN v_qty > 0 THEN v_avg ELSE 0 END;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- Production safety: do not auto-run a historical GL/inventory repair during
-- migration apply. Run manually after a backup and operator approval:
-- SELECT * FROM public.repair_inventory_gl_from_wac();

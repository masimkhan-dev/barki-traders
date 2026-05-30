BEGIN;

-- ============================================================
-- FIX: DOUBLE TRIGGER INVENTORY BUG
-- ============================================================
-- Problem: Two triggers were firing on DELETE for both sales
-- and purchases:
--   1. trg_sale_delete_cascade   (BEFORE DELETE) - from old migration
--   2. trg_sale_ledger_strict    (AFTER DELETE)  - from new migration
-- Same issue for purchases with:
--   1. trg_purchase_delete_cascade  (BEFORE DELETE) - from old migration
--   2. trg_purchase_ledger_strict   (AFTER DELETE)  - from new migration
--
-- Result: Stock was deducted TWICE on delete, zeroing inventory.
-- Also on UPDATE for purchases: old sync_purchase_v11 might still
-- have a residual trigger. We drop ALL legacy cascade/delete triggers.
-- The new "AFTER INSERT OR UPDATE OR DELETE" triggers handle everything.
-- ============================================================

-- 1. Drop old BEFORE DELETE cascade triggers (legacy from phase1_trigger_hardening)
DROP TRIGGER IF EXISTS trg_sale_delete_cascade ON public.sales;
DROP TRIGGER IF EXISTS trg_purchase_delete_cascade ON public.purchases;
DROP TRIGGER IF EXISTS trg_payment_delete_cascade ON public.payments;

-- 2. Drop any residual old-era triggers that might still exist
DROP TRIGGER IF EXISTS trg_sale_ledger_final ON public.sales;
DROP TRIGGER IF EXISTS trg_purchase_ledger_final ON public.purchases;
DROP TRIGGER IF EXISTS sync_purchase_v11_trigger ON public.purchases;
DROP TRIGGER IF EXISTS sync_sale_v11_trigger ON public.sales;

-- 3. Verify the proc_purchase_ledger_strict and proc_sale_ledger_strict
--    handle DELETE correctly (they already do — stock reversal + ledger delete).
--    These are the ONLY triggers that should fire now:
--      trg_sale_ledger_strict     AFTER INSERT OR UPDATE OR DELETE ON sales
--      trg_purchase_ledger_strict AFTER INSERT OR UPDATE OR DELETE ON purchases

-- 4. Ensure update_stock_quantity handles the case where inventory row
--    doesn't exist on IN (safe upsert instead of silent no-op)
CREATE OR REPLACE FUNCTION public.update_stock_quantity(
    _fuel_type_id UUID,
    _quantity NUMERIC,
    _direction TEXT
)
RETURNS VOID AS $$
DECLARE
    v_current_qty NUMERIC;
BEGIN
    IF _direction = 'OUT' THEN
        SELECT quantity INTO v_current_qty
        FROM inventory
        WHERE fuel_type_id = _fuel_type_id;

        IF v_current_qty IS NULL OR (v_current_qty - _quantity) < 0 THEN
            RAISE EXCEPTION
                'INVENTORY BLOCKED: Insufficient stock. Current: %, Requested OUT: %',
                COALESCE(v_current_qty, 0), _quantity;
        END IF;

        UPDATE inventory
        SET quantity     = quantity - _quantity,
            last_updated = NOW()
        WHERE fuel_type_id = _fuel_type_id;

    ELSIF _direction = 'IN' THEN
        -- Try UPDATE first
        UPDATE inventory
        SET quantity     = quantity + _quantity,
            last_updated = NOW()
        WHERE fuel_type_id = _fuel_type_id;

        -- If no row existed, INSERT (first purchase of this fuel type)
        IF NOT FOUND THEN
            INSERT INTO inventory (fuel_type_id, quantity, last_updated)
            VALUES (_fuel_type_id, _quantity, NOW())
            ON CONFLICT (fuel_type_id) DO UPDATE
                SET quantity     = inventory.quantity + EXCLUDED.quantity,
                    last_updated = NOW();
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- 5. Reload schema cache
NOTIFY pgrst, 'reload schema';

COMMIT;

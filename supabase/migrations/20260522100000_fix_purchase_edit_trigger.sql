BEGIN;

SET search_path = public;

-- Drop old trigger first
DROP TRIGGER IF EXISTS sync_purchase_v11_trigger ON public.purchases;

CREATE OR REPLACE FUNCTION public.sync_purchase_v11()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inv_id uuid;
    v_ap_id uuid;
    v_qty numeric := 0;
    v_cost numeric := 0;
    v_new_qty numeric := 0;
    v_new_cost numeric := 0;
    v_new_value numeric := 0;
    v_delta numeric := 0;
    v_stock_changed boolean := false;
    v_rate_changed boolean := false;
    v_ledger_changed boolean := false;
BEGIN
    SELECT id INTO v_inv_id FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';

    IF v_inv_id IS NULL OR v_ap_id IS NULL THEN
        RAISE EXCEPTION 'PURCHASE TRIGGER ERROR: required control accounts missing.';
    END IF;

    -- ==========================================
    -- 1. INSERT OPERATION
    -- ==========================================
    IF TG_OP = 'INSERT' THEN
        IF NEW.quantity <= 0 THEN
            RAISE EXCEPTION 'PURCHASE ERROR: Quantity must be positive. Got: %', NEW.quantity;
        END IF;

        SELECT quantity, avg_cost INTO v_qty, v_cost
        FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
            VALUES (NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit, now());
        ELSE
            v_new_qty := COALESCE(v_qty, 0) + NEW.quantity;
            IF v_new_qty > 0 THEN
                v_new_cost := ((COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) + (NEW.quantity * NEW.rate_per_unit)) / v_new_qty;
            ELSE
                v_new_cost := NEW.rate_per_unit;
            END IF;

            UPDATE public.inventory
            SET quantity = v_new_qty, avg_cost = v_new_cost, last_updated = now()
            WHERE fuel_type_id = NEW.fuel_type_id;
        END IF;

        DELETE FROM public.ledger_entries WHERE voucher_no = NEW.voucher_no;

        INSERT INTO public.ledger_entries (
            voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by
        )
        VALUES
            (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv_id, NULL, NEW.total_amount, 0, COALESCE(NULLIF(NEW.notes, ''), 'Inventory Purchase'), COALESCE(NEW.created_by, auth.uid())),
            (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id, 0, NEW.total_amount, 'Accounts Payable', COALESCE(NEW.created_by, auth.uid()));

        RETURN NEW;
    END IF;

    -- ==========================================
    -- 2. DELETE OPERATION
    -- ==========================================
    IF TG_OP = 'DELETE' THEN
        SELECT quantity, avg_cost INTO v_qty, v_cost
        FROM public.inventory WHERE fuel_type_id = OLD.fuel_type_id FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'PURCHASE DELETE BLOCKED: stock record not found for selected fuel type.';
        END IF;

        -- Strict Delete validation: Must have full quantity in stock
        IF COALESCE(v_qty, 0) < OLD.quantity THEN
            RAISE EXCEPTION 'STOCK INTEGRITY ERROR: Cannot cancel purchase. Current stock (% L) is less than purchase quantity (% L). Some stock has already been sold.', COALESCE(v_qty, 0), OLD.quantity;
        END IF;

        PERFORM public.compat_log_purchase_change(OLD.id, TG_OP, row_to_json(OLD)::jsonb, NULL);

        v_new_qty := COALESCE(v_qty, 0) - OLD.quantity;
        v_new_value := (COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) - (OLD.quantity * OLD.rate_per_unit);

        IF v_new_qty > 0 THEN
            v_new_cost := GREATEST(v_new_value, 0) / v_new_qty;
        ELSE
            v_new_cost := 0;
        END IF;

        UPDATE public.inventory
        SET quantity = v_new_qty, avg_cost = v_new_cost, last_updated = now()
        WHERE fuel_type_id = OLD.fuel_type_id;

        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

        RETURN OLD;
    END IF;

    -- ==========================================
    -- 3. UPDATE OPERATION
    -- ==========================================
    IF TG_OP = 'UPDATE' THEN
        IF NEW.quantity <= 0 THEN
            RAISE EXCEPTION 'PURCHASE ERROR: Quantity must be positive. Got: %', NEW.quantity;
        END IF;

        v_stock_changed :=
            OLD.fuel_type_id IS DISTINCT FROM NEW.fuel_type_id
            OR OLD.quantity IS DISTINCT FROM NEW.quantity;

        v_rate_changed := OLD.rate_per_unit IS DISTINCT FROM NEW.rate_per_unit;

        v_ledger_changed :=
            v_stock_changed
            OR v_rate_changed
            OR OLD.total_amount IS DISTINCT FROM NEW.total_amount
            OR OLD.purchase_date IS DISTINCT FROM NEW.purchase_date
            OR OLD.party_id IS DISTINCT FROM NEW.party_id
            OR OLD.is_paid_now IS DISTINCT FROM NEW.is_paid_now
            OR OLD.payment_method IS DISTINCT FROM NEW.payment_method
            OR OLD.notes IS DISTINCT FROM NEW.notes;

        PERFORM public.compat_log_purchase_change(OLD.id, TG_OP, row_to_json(OLD)::jsonb, row_to_json(NEW)::jsonb);

        -- Smart Validation & Stock Operations
        IF OLD.fuel_type_id IS DISTINCT FROM NEW.fuel_type_id THEN
            -- Fuel type changed: Treat as Delete (Strict) + Insert
            SELECT quantity, avg_cost INTO v_qty, v_cost
            FROM public.inventory WHERE fuel_type_id = OLD.fuel_type_id FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'PURCHASE EDIT BLOCKED: original stock record not found.';
            END IF;

            IF COALESCE(v_qty, 0) < OLD.quantity THEN
                RAISE EXCEPTION 'PURCHASE EDIT BLOCKED: cannot change fuel type because only % L is available from old stock, but % L must be moved.', COALESCE(v_qty, 0), OLD.quantity;
            END IF;

            -- Deduct old fuel type
            v_new_qty := COALESCE(v_qty, 0) - OLD.quantity;
            v_new_value := (COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) - (OLD.quantity * OLD.rate_per_unit);
            IF v_new_qty > 0 THEN
                v_new_cost := GREATEST(v_new_value, 0) / v_new_qty;
            ELSE
                v_new_cost := 0;
            END IF;

            UPDATE public.inventory
            SET quantity = v_new_qty, avg_cost = v_new_cost, last_updated = now()
            WHERE fuel_type_id = OLD.fuel_type_id;

            -- Add to new fuel type
            INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
            VALUES (NEW.fuel_type_id, 0, 0, now())
            ON CONFLICT (fuel_type_id) DO NOTHING;

            SELECT quantity, avg_cost INTO v_qty, v_cost
            FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

            v_new_qty := COALESCE(v_qty, 0) + NEW.quantity;
            IF v_new_qty > 0 THEN
                v_new_cost := ((COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) + (NEW.quantity * NEW.rate_per_unit)) / v_new_qty;
            ELSE
                v_new_cost := NEW.rate_per_unit;
            END IF;

            UPDATE public.inventory
            SET quantity = v_new_qty, avg_cost = v_new_cost, last_updated = now()
            WHERE fuel_type_id = NEW.fuel_type_id;

        ELSIF v_stock_changed OR v_rate_changed THEN
            -- Same fuel type: Stock or Rate changed
            SELECT quantity, avg_cost INTO v_qty, v_cost
            FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'PURCHASE EDIT BLOCKED: stock record not found.';
            END IF;

            v_delta := NEW.quantity - OLD.quantity;
            
            -- Smart check: Only validate stock reduction amount
            IF v_delta < 0 AND COALESCE(v_qty, 0) < abs(v_delta) THEN
                RAISE EXCEPTION 'PURCHASE EDIT BLOCKED: only % L is available, but reducing this purchase requires % L available.', COALESCE(v_qty, 0), abs(v_delta);
            END IF;

            -- Apply subtraction of old then addition of new (pure double-entry subtraction-then-addition pattern)
            v_new_qty := COALESCE(v_qty, 0) - OLD.quantity + NEW.quantity;
            v_new_value := (COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) - (OLD.quantity * OLD.rate_per_unit) + (NEW.quantity * NEW.rate_per_unit);

            IF v_new_qty > 0 THEN
                v_new_cost := GREATEST(v_new_value, 0) / v_new_qty;
            ELSE
                v_new_cost := NEW.rate_per_unit;
            END IF;

            UPDATE public.inventory
            SET quantity = v_new_qty, avg_cost = v_new_cost, last_updated = now()
            WHERE fuel_type_id = NEW.fuel_type_id;
        
        -- NOTE: If neither v_stock_changed nor v_rate_changed is true, inventory is left untouched.
        -- Simple narration, party, or date changes are 100% allowed even with 0 stock!
        END IF;

        -- Step B: Rebuild or Update Ledger Entries
        IF v_ledger_changed THEN
            -- If only notes/narration changed, do a simple in-place UPDATE to keep it extremely fast and lightweight
            IF NOT v_stock_changed AND NOT v_rate_changed 
               AND OLD.purchase_date IS NOT DISTINCT FROM NEW.purchase_date
               AND OLD.party_id IS NOT DISTINCT FROM NEW.party_id
               AND OLD.total_amount IS NOT DISTINCT FROM NEW.total_amount
            THEN
                UPDATE public.ledger_entries
                SET narration = COALESCE(NULLIF(NEW.notes, ''), 'Inventory Purchase')
                WHERE voucher_no = NEW.voucher_no AND account_id = v_inv_id;
            ELSE
                -- Full rebuild for key financial changes (amount, date, party, etc.)
                DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

                INSERT INTO public.ledger_entries (
                    voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by
                )
                VALUES
                    (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv_id, NULL, NEW.total_amount, 0, COALESCE(NULLIF(NEW.notes, ''), 'Inventory Purchase'), COALESCE(NEW.created_by, auth.uid())),
                    (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id, 0, NEW.total_amount, 'Accounts Payable', COALESCE(NEW.created_by, auth.uid()));
            END IF;
        END IF;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;

-- Create trigger again
CREATE TRIGGER sync_purchase_v11_trigger
AFTER INSERT OR UPDATE OR DELETE ON public.purchases
FOR EACH ROW EXECUTE FUNCTION public.sync_purchase_v11();

NOTIFY pgrst, 'reload schema';

COMMIT;

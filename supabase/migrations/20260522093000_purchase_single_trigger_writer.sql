BEGIN;

SET search_path = public;

CREATE OR REPLACE FUNCTION public.compat_log_purchase_change(
    p_record_id uuid,
    p_action text,
    p_old_values jsonb,
    p_new_values jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_has_old_values boolean;
    v_has_old_data boolean;
BEGIN
    IF to_regclass('public.audit_logs') IS NULL THEN
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'audit_logs'
          AND column_name = 'old_values'
    )
    INTO v_has_old_values;

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'audit_logs'
          AND column_name = 'old_data'
    )
    INTO v_has_old_data;

    IF v_has_old_values THEN
        INSERT INTO public.audit_logs (
            table_name,
            record_id,
            action,
            old_values,
            new_values,
            changed_by
        )
        VALUES (
            'purchases',
            p_record_id,
            p_action,
            p_old_values,
            p_new_values,
            auth.uid()
        );
    ELSIF v_has_old_data THEN
        INSERT INTO public.audit_logs (
            table_name,
            record_id,
            action,
            old_data,
            new_data,
            changed_by
        )
        VALUES (
            'purchases',
            p_record_id,
            p_action,
            p_old_values,
            p_new_values,
            auth.uid()
        );
    END IF;
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$;

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

    IF TG_OP = 'INSERT' THEN
        IF NEW.quantity <= 0 THEN
            RAISE EXCEPTION 'PURCHASE ERROR: Quantity must be positive. Got: %', NEW.quantity;
        END IF;

        SELECT quantity, avg_cost
        INTO v_qty, v_cost
        FROM public.inventory
        WHERE fuel_type_id = NEW.fuel_type_id
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
            VALUES (NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit, now());
        ELSE
            v_new_qty := COALESCE(v_qty, 0) + NEW.quantity;

            IF v_new_qty > 0 THEN
                v_new_cost := (
                    (COALESCE(v_qty, 0) * COALESCE(v_cost, 0))
                    + (NEW.quantity * NEW.rate_per_unit)
                ) / v_new_qty;
            ELSE
                v_new_cost := NEW.rate_per_unit;
            END IF;

            UPDATE public.inventory
            SET quantity = v_new_qty,
                avg_cost = v_new_cost,
                last_updated = now()
            WHERE fuel_type_id = NEW.fuel_type_id;
        END IF;

        DELETE FROM public.ledger_entries WHERE voucher_no = NEW.voucher_no;

        INSERT INTO public.ledger_entries (
            voucher_no,
            voucher_type,
            posting_date,
            account_id,
            party_id,
            debit_amount,
            credit_amount,
            narration,
            created_by
        )
        VALUES
            (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv_id, NULL, NEW.total_amount, 0, COALESCE(NULLIF(NEW.notes, ''), 'Inventory Purchase'), COALESCE(NEW.created_by, auth.uid())),
            (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id, 0, NEW.total_amount, 'Accounts Payable', COALESCE(NEW.created_by, auth.uid()));

        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        SELECT quantity, avg_cost
        INTO v_qty, v_cost
        FROM public.inventory
        WHERE fuel_type_id = OLD.fuel_type_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'PURCHASE DELETE BLOCKED: stock record not found for selected fuel type.';
        END IF;

        IF COALESCE(v_qty, 0) < OLD.quantity THEN
            RAISE EXCEPTION 'STOCK INTEGRITY ERROR: Cannot cancel purchase. Current stock (%) is less than purchase quantity (%). Some stock has already been sold.', COALESCE(v_qty, 0), OLD.quantity;
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
        SET quantity = v_new_qty,
            avg_cost = v_new_cost,
            last_updated = now()
        WHERE fuel_type_id = OLD.fuel_type_id;

        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

        RETURN OLD;
    END IF;

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

        IF OLD.fuel_type_id IS DISTINCT FROM NEW.fuel_type_id THEN
            SELECT quantity, avg_cost
            INTO v_qty, v_cost
            FROM public.inventory
            WHERE fuel_type_id = OLD.fuel_type_id
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'PURCHASE EDIT BLOCKED: original stock record not found.';
            END IF;

            IF COALESCE(v_qty, 0) < OLD.quantity THEN
                RAISE EXCEPTION 'PURCHASE EDIT BLOCKED: cannot change fuel type because only % L is available from old stock, but % L must be moved.', COALESCE(v_qty, 0), OLD.quantity;
            END IF;

            v_new_qty := COALESCE(v_qty, 0) - OLD.quantity;
            v_new_value := (COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) - (OLD.quantity * OLD.rate_per_unit);

            IF v_new_qty > 0 THEN
                v_new_cost := GREATEST(v_new_value, 0) / v_new_qty;
            ELSE
                v_new_cost := 0;
            END IF;

            UPDATE public.inventory
            SET quantity = v_new_qty,
                avg_cost = v_new_cost,
                last_updated = now()
            WHERE fuel_type_id = OLD.fuel_type_id;

            SELECT quantity, avg_cost
            INTO v_qty, v_cost
            FROM public.inventory
            WHERE fuel_type_id = NEW.fuel_type_id
            FOR UPDATE;

            IF NOT FOUND THEN
                INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
                VALUES (NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit, now());
            ELSE
                v_new_qty := COALESCE(v_qty, 0) + NEW.quantity;

                IF v_new_qty > 0 THEN
                    v_new_cost := (
                        (COALESCE(v_qty, 0) * COALESCE(v_cost, 0))
                        + (NEW.quantity * NEW.rate_per_unit)
                    ) / v_new_qty;
                ELSE
                    v_new_cost := NEW.rate_per_unit;
                END IF;

                UPDATE public.inventory
                SET quantity = v_new_qty,
                    avg_cost = v_new_cost,
                    last_updated = now()
                WHERE fuel_type_id = NEW.fuel_type_id;
            END IF;
        ELSE
            SELECT quantity, avg_cost
            INTO v_qty, v_cost
            FROM public.inventory
            WHERE fuel_type_id = NEW.fuel_type_id
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'PURCHASE EDIT BLOCKED: stock record not found for selected fuel type.';
            END IF;

            v_delta := NEW.quantity - OLD.quantity;

            IF v_delta < 0 AND COALESCE(v_qty, 0) < abs(v_delta) THEN
                RAISE EXCEPTION 'PURCHASE EDIT BLOCKED: only % L is available, but reducing this purchase requires % L available.', COALESCE(v_qty, 0), abs(v_delta);
            END IF;

            IF v_rate_changed AND COALESCE(v_qty, 0) < OLD.quantity THEN
                RAISE EXCEPTION 'PURCHASE EDIT BLOCKED: rate edit requires % L available, but current stock is % L. Some stock has already been sold.', OLD.quantity, COALESCE(v_qty, 0);
            END IF;

            IF v_delta > 0 THEN
                v_new_qty := COALESCE(v_qty, 0) + v_delta;
                v_new_cost := (
                    (COALESCE(v_qty, 0) * COALESCE(v_cost, 0))
                    + (v_delta * NEW.rate_per_unit)
                ) / v_new_qty;
            ELSIF v_delta < 0 THEN
                v_new_qty := COALESCE(v_qty, 0) + v_delta;
                v_new_value := (COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) - (abs(v_delta) * OLD.rate_per_unit);
                IF v_new_qty > 0 THEN
                    v_new_cost := GREATEST(v_new_value, 0) / v_new_qty;
                ELSE
                    v_new_cost := 0;
                END IF;
            ELSIF v_rate_changed THEN
                v_new_qty := COALESCE(v_qty, 0);
                v_new_value := (COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) - (OLD.quantity * OLD.rate_per_unit) + (NEW.quantity * NEW.rate_per_unit);
                IF v_new_qty > 0 THEN
                    v_new_cost := GREATEST(v_new_value, 0) / v_new_qty;
                ELSE
                    v_new_cost := 0;
                END IF;
            ELSE
                v_new_qty := COALESCE(v_qty, 0);
                v_new_cost := COALESCE(v_cost, 0);
            END IF;

            IF v_stock_changed OR v_rate_changed THEN
                UPDATE public.inventory
                SET quantity = v_new_qty,
                    avg_cost = v_new_cost,
                    last_updated = now()
                WHERE fuel_type_id = NEW.fuel_type_id;
            END IF;
        END IF;

        IF v_ledger_changed THEN
            DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

            INSERT INTO public.ledger_entries (
                voucher_no,
                voucher_type,
                posting_date,
                account_id,
                party_id,
                debit_amount,
                credit_amount,
                narration,
                created_by
            )
            VALUES
                (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv_id, NULL, NEW.total_amount, 0, COALESCE(NULLIF(NEW.notes, ''), 'Inventory Purchase'), COALESCE(NEW.created_by, auth.uid())),
                (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id, 0, NEW.total_amount, 'Accounts Payable', COALESCE(NEW.created_by, auth.uid()));
        END IF;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS sync_purchase_v11_trigger ON public.purchases;
DROP TRIGGER IF EXISTS sync_purchase_trigger ON public.purchases;
DROP TRIGGER IF EXISTS trigger_auto_post_purchase ON public.purchases;
DROP TRIGGER IF EXISTS trigger_purchase_ledger ON public.purchases;
DROP TRIGGER IF EXISTS purchase_ledger_trigger ON public.purchases;
DROP TRIGGER IF EXISTS trg_purchase_ledger ON public.purchases;
DROP TRIGGER IF EXISTS trigger_purchase_inventory ON public.purchases;
DROP TRIGGER IF EXISTS on_purchase_update_inventory ON public.purchases;
DROP TRIGGER IF EXISTS trigger_purchase_ledger_entries ON public.purchases;
DROP TRIGGER IF EXISTS trg_purchase_ledger_final ON public.purchases;
DROP TRIGGER IF EXISTS trg_purchase_ledger_strict ON public.purchases;
DROP TRIGGER IF EXISTS trg_purchase_delete_cascade ON public.purchases;

CREATE TRIGGER sync_purchase_v11_trigger
AFTER INSERT OR UPDATE OR DELETE ON public.purchases
FOR EACH ROW EXECUTE FUNCTION public.sync_purchase_v11();

GRANT EXECUTE ON FUNCTION public.compat_log_purchase_change(uuid, text, jsonb, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
    trigger_name,
    event_manipulation,
    action_timing,
    action_statement
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table = 'purchases'
ORDER BY trigger_name, event_manipulation;

COMMIT;

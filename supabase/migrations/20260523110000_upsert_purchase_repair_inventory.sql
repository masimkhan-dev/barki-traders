BEGIN;

SET search_path = public;

-- Allow RPC-driven edits even if legacy hardening triggers remain on the project DB.
DROP TRIGGER IF EXISTS prevent_purchases_update ON public.purchases;
DROP TRIGGER IF EXISTS prevent_purchases_delete ON public.purchases;
DROP TRIGGER IF EXISTS prevent_sales_update ON public.sales;
DROP TRIGGER IF EXISTS prevent_sales_delete ON public.sales;

-- Create or update a purchase row by voucher (used when ledger exists but purchases row is missing).
CREATE OR REPLACE FUNCTION public.upsert_purchase_transaction(
    p_voucher_no text,
    p_purchase_date date,
    p_party_id uuid,
    p_fuel_type_id uuid,
    p_quantity numeric,
    p_rate_per_unit numeric,
    p_total_amount numeric,
    p_is_paid_now boolean DEFAULT false,
    p_payment_method text DEFAULT 'Cash',
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_exists boolean;
    v_edit_result jsonb;
BEGIN
    IF NOT public.compat_can_edit_transactions() THEN
        RETURN jsonb_build_object('success', false, 'error', 'permission denied');
    END IF;

    IF p_voucher_no IS NULL OR btrim(p_voucher_no) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'voucher not found');
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.purchases WHERE voucher_no = p_voucher_no
    )
    INTO v_exists;

    IF v_exists THEN
        v_edit_result := public.edit_purchase_transaction(
            p_original_voucher_no := p_voucher_no,
            p_purchase_date := p_purchase_date,
            p_party_id := p_party_id,
            p_fuel_type_id := p_fuel_type_id,
            p_quantity := p_quantity,
            p_rate_per_unit := p_rate_per_unit,
            p_total_amount := p_total_amount,
            p_is_paid_now := p_is_paid_now,
            p_payment_method := p_payment_method,
            p_notes := p_notes
        );
        RETURN v_edit_result;
    END IF;

    INSERT INTO public.purchases (
        voucher_no,
        purchase_date,
        party_id,
        fuel_type_id,
        quantity,
        rate_per_unit,
        total_amount,
        is_paid_now,
        payment_method,
        notes,
        created_by
    )
    VALUES (
        p_voucher_no,
        p_purchase_date,
        p_party_id,
        p_fuel_type_id,
        p_quantity,
        p_rate_per_unit,
        p_total_amount,
        COALESCE(p_is_paid_now, false),
        p_payment_method,
        p_notes,
        auth.uid()
    );

    RETURN jsonb_build_object(
        'success', true,
        'voucher_no', p_voucher_no,
        'message', 'Purchase row created. Trigger synced ledger and stock.'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- Reconcile inventory.quantity from source vouchers (purchases minus sales).
CREATE OR REPLACE FUNCTION public.repair_inventory_from_transactions()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_updated integer := 0;
BEGIN
    IF NOT public.compat_can_edit_transactions() THEN
        RETURN jsonb_build_object('success', false, 'error', 'permission denied');
    END IF;

    INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
    SELECT ft.id, 0, 0, now()
    FROM public.fuel_types ft
    WHERE ft.is_active = true
    ON CONFLICT (fuel_type_id) DO NOTHING;

    UPDATE public.inventory i
    SET
        quantity = sub.qty,
        last_updated = now()
    FROM (
        SELECT
            ft.id AS fuel_type_id,
            GREATEST(COALESCE(p.total_qty, 0) - COALESCE(s.total_qty, 0), 0) AS qty
        FROM public.fuel_types ft
        LEFT JOIN (
            SELECT fuel_type_id, SUM(quantity) AS total_qty
            FROM public.purchases
            GROUP BY fuel_type_id
        ) p ON p.fuel_type_id = ft.id
        LEFT JOIN (
            SELECT fuel_type_id, SUM(quantity) AS total_qty
            FROM public.sales
            GROUP BY fuel_type_id
        ) s ON s.fuel_type_id = ft.id
    ) sub
    WHERE i.fuel_type_id = sub.fuel_type_id;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'rows_updated', v_updated,
        'message', 'Inventory quantities reconciled from purchases and sales.'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_purchase_transaction(
    text, date, uuid, uuid, numeric, numeric, numeric, boolean, text, text
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.repair_inventory_from_transactions() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

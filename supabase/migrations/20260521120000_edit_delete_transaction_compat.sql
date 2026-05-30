BEGIN;

SET search_path = public;

CREATE OR REPLACE FUNCTION public.compat_can_edit_transactions()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT auth.uid() IS NOT NULL
       AND EXISTS (
            SELECT 1
            FROM public.user_roles ur
            WHERE ur.user_id = auth.uid()
              AND ur.role::text IN ('admin', 'accountant', 'manager')
       );
$$;

CREATE OR REPLACE FUNCTION public.compat_voucher_is_reversed(
    p_table_name text,
    p_voucher_no text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_has_column boolean;
    v_is_reversed boolean := false;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = p_table_name
          AND column_name = 'is_reversed'
    )
    INTO v_has_column;

    IF NOT v_has_column THEN
        RETURN false;
    END IF;

    EXECUTE format(
        'SELECT COALESCE(is_reversed, false) FROM public.%I WHERE voucher_no = $1 LIMIT 1',
        p_table_name
    )
    INTO v_is_reversed
    USING p_voucher_no;

    RETURN COALESCE(v_is_reversed, false);
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_purchase_transaction(
    p_original_voucher_no text,
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
    v_purchase public.purchases%ROWTYPE;
    v_current_stock numeric := 0;
    v_expected_total numeric;
BEGIN
    IF NOT public.compat_can_edit_transactions() THEN
        RETURN jsonb_build_object('success', false, 'error', 'permission denied');
    END IF;

    IF p_original_voucher_no IS NULL OR btrim(p_original_voucher_no) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'voucher not found');
    END IF;

    IF p_party_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing supplier');
    END IF;

    IF p_fuel_type_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing fuel type');
    END IF;

    IF COALESCE(p_quantity, 0) <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid quantity');
    END IF;

    IF COALESCE(p_rate_per_unit, 0) <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid rate');
    END IF;

    v_expected_total := round(p_quantity * p_rate_per_unit, 2);
    IF abs(round(COALESCE(p_total_amount, 0), 2) - v_expected_total) > 0.01 THEN
        RETURN jsonb_build_object('success', false, 'error', 'amount does not match quantity x rate');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.parties WHERE id = p_party_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing supplier');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.fuel_types WHERE id = p_fuel_type_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing fuel type');
    END IF;

    SELECT *
    INTO v_purchase
    FROM public.purchases
    WHERE voucher_no = p_original_voucher_no
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'voucher not found');
    END IF;

    IF public.compat_voucher_is_reversed('purchases', p_original_voucher_no) THEN
        RETURN jsonb_build_object('success', false, 'error', 'transaction already reversed');
    END IF;

    IF v_purchase.fuel_type_id = p_fuel_type_id THEN
        SELECT quantity INTO v_current_stock
        FROM public.inventory
        WHERE fuel_type_id = v_purchase.fuel_type_id
        FOR UPDATE;

        IF (COALESCE(v_current_stock, 0) - v_purchase.quantity + p_quantity) < 0 THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'insufficient stock to reduce this purchase because some quantity has already been sold'
            );
        END IF;
    ELSE
        SELECT quantity INTO v_current_stock
        FROM public.inventory
        WHERE fuel_type_id = v_purchase.fuel_type_id
        FOR UPDATE;

        IF (COALESCE(v_current_stock, 0) - v_purchase.quantity) < 0 THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'insufficient stock to move this purchase away from the original fuel type'
            );
        END IF;
    END IF;

    UPDATE public.purchases
    SET purchase_date = p_purchase_date,
        party_id = p_party_id,
        fuel_type_id = p_fuel_type_id,
        quantity = p_quantity,
        rate_per_unit = p_rate_per_unit,
        total_amount = p_total_amount,
        is_paid_now = COALESCE(p_is_paid_now, false),
        payment_method = p_payment_method,
        notes = p_notes
    WHERE voucher_no = p_original_voucher_no;

    RETURN jsonb_build_object(
        'success', true,
        'voucher_no', p_original_voucher_no,
        'message', 'Purchase updated. Existing purchase trigger synced ledger and stock.'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_sale_transaction(
    p_original_voucher_no text,
    p_sale_date date,
    p_party_id uuid,
    p_fuel_type_id uuid,
    p_quantity numeric,
    p_rate_per_unit numeric,
    p_total_amount numeric,
    p_is_credit boolean DEFAULT true,
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_sale public.sales%ROWTYPE;
    v_available_stock numeric := 0;
    v_expected_total numeric;
BEGIN
    IF NOT public.compat_can_edit_transactions() THEN
        RETURN jsonb_build_object('success', false, 'error', 'permission denied');
    END IF;

    IF p_original_voucher_no IS NULL OR btrim(p_original_voucher_no) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'voucher not found');
    END IF;

    IF p_party_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing customer');
    END IF;

    IF p_fuel_type_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing fuel type');
    END IF;

    IF COALESCE(p_quantity, 0) <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid quantity');
    END IF;

    IF COALESCE(p_rate_per_unit, 0) <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid rate');
    END IF;

    v_expected_total := round(p_quantity * p_rate_per_unit, 2);
    IF abs(round(COALESCE(p_total_amount, 0), 2) - v_expected_total) > 0.01 THEN
        RETURN jsonb_build_object('success', false, 'error', 'amount does not match quantity x rate');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.parties WHERE id = p_party_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing customer');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.fuel_types WHERE id = p_fuel_type_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing fuel type');
    END IF;

    SELECT *
    INTO v_sale
    FROM public.sales
    WHERE voucher_no = p_original_voucher_no
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'voucher not found');
    END IF;

    IF public.compat_voucher_is_reversed('sales', p_original_voucher_no) THEN
        RETURN jsonb_build_object('success', false, 'error', 'transaction already reversed');
    END IF;

    SELECT quantity INTO v_available_stock
    FROM public.inventory
    WHERE fuel_type_id = p_fuel_type_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'stock record not found for selected fuel type');
    END IF;

    IF v_sale.fuel_type_id = p_fuel_type_id THEN
        v_available_stock := COALESCE(v_available_stock, 0) + v_sale.quantity;
    END IF;

    IF COALESCE(v_available_stock, 0) < p_quantity THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'insufficient stock',
            'available_stock', COALESCE(v_available_stock, 0),
            'requested_quantity', p_quantity
        );
    END IF;

    UPDATE public.sales
    SET sale_date = p_sale_date,
        party_id = p_party_id,
        fuel_type_id = p_fuel_type_id,
        quantity = p_quantity,
        rate_per_unit = p_rate_per_unit,
        total_amount = p_total_amount,
        is_credit = COALESCE(p_is_credit, true),
        notes = p_notes
    WHERE voucher_no = p_original_voucher_no;

    RETURN jsonb_build_object(
        'success', true,
        'voucher_no', p_original_voucher_no,
        'message', 'Sale updated. Existing sale trigger synced ledger and stock.'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_purchase_transaction(
    p_voucher_no text,
    p_reason text DEFAULT 'Deleted from UI'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_purchase public.purchases%ROWTYPE;
    v_current_stock numeric := 0;
BEGIN
    IF NOT public.compat_can_edit_transactions() THEN
        RETURN jsonb_build_object('success', false, 'error', 'permission denied');
    END IF;

    SELECT *
    INTO v_purchase
    FROM public.purchases
    WHERE voucher_no = p_voucher_no
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'voucher not found');
    END IF;

    IF public.compat_voucher_is_reversed('purchases', p_voucher_no) THEN
        RETURN jsonb_build_object('success', false, 'error', 'transaction already reversed');
    END IF;

    SELECT quantity INTO v_current_stock
    FROM public.inventory
    WHERE fuel_type_id = v_purchase.fuel_type_id
    FOR UPDATE;

    IF (COALESCE(v_current_stock, 0) - v_purchase.quantity) < 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'insufficient stock to cancel this purchase because some quantity has already been sold'
        );
    END IF;

    DELETE FROM public.purchases
    WHERE voucher_no = p_voucher_no;

    RETURN jsonb_build_object(
        'success', true,
        'voucher_no', p_voucher_no,
        'message', 'Purchase cancelled through existing purchase DELETE trigger.',
        'strategy', 'trigger-backed source delete'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_sale_transaction(
    p_voucher_no text,
    p_reason text DEFAULT 'Deleted from UI'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_sale public.sales%ROWTYPE;
BEGIN
    IF NOT public.compat_can_edit_transactions() THEN
        RETURN jsonb_build_object('success', false, 'error', 'permission denied');
    END IF;

    SELECT *
    INTO v_sale
    FROM public.sales
    WHERE voucher_no = p_voucher_no
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'voucher not found');
    END IF;

    IF public.compat_voucher_is_reversed('sales', p_voucher_no) THEN
        RETURN jsonb_build_object('success', false, 'error', 'transaction already reversed');
    END IF;

    DELETE FROM public.sales
    WHERE voucher_no = p_voucher_no;

    RETURN jsonb_build_object(
        'success', true,
        'voucher_no', p_voucher_no,
        'message', 'Sale cancelled through existing sale DELETE trigger.',
        'strategy', 'trigger-backed source delete'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_transaction_safely(
    p_voucher_no text,
    p_reason text DEFAULT 'Deleted from UI'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result jsonb;
    v_deleted_count integer := 0;
BEGIN
    IF NOT public.compat_can_edit_transactions() THEN
        RETURN jsonb_build_object('success', false, 'error', 'permission denied');
    END IF;

    IF p_voucher_no IS NULL OR btrim(p_voucher_no) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'voucher not found');
    END IF;

    IF EXISTS (SELECT 1 FROM public.sales WHERE voucher_no = p_voucher_no) THEN
        SELECT public.cancel_sale_transaction(p_voucher_no, p_reason) INTO v_result;
        RETURN v_result;
    END IF;

    IF EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = p_voucher_no) THEN
        SELECT public.cancel_purchase_transaction(p_voucher_no, p_reason) INTO v_result;
        RETURN v_result;
    END IF;

    IF to_regclass('public.payments') IS NOT NULL THEN
        EXECUTE 'DELETE FROM public.payments WHERE voucher_no = $1' USING p_voucher_no;
        GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

        IF v_deleted_count > 0 THEN
            RETURN jsonb_build_object(
                'success', true,
                'voucher_no', p_voucher_no,
                'message', 'Payment transaction cancelled through existing payment delete path.'
            );
        END IF;
    END IF;

    DELETE FROM public.ledger_entries
    WHERE voucher_no = p_voucher_no;
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    IF v_deleted_count > 0 THEN
        RETURN jsonb_build_object(
            'success', true,
            'voucher_no', p_voucher_no,
            'message', 'Ledger-only voucher removed through safe RPC.'
        );
    END IF;

    RETURN jsonb_build_object('success', false, 'error', 'voucher not found');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.reverse_transaction_safely(
    p_voucher_no text,
    p_reason text DEFAULT 'Reversed for edit'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.delete_transaction_safely(p_voucher_no, p_reason);
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_transaction_safely(
    p_voucher_no text,
    p_reason text DEFAULT 'Cancelled from UI'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.delete_transaction_safely(p_voucher_no, p_reason);
END;
$$;

GRANT EXECUTE ON FUNCTION public.edit_purchase_transaction(text, date, uuid, uuid, numeric, numeric, numeric, boolean, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_sale_transaction(text, date, uuid, uuid, numeric, numeric, numeric, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_purchase_transaction(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_sale_transaction(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_transaction_safely(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reverse_transaction_safely(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_transaction_safely(text, text) TO authenticated;

COMMIT;

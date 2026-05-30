-- Fix: post_sale/post_purchase reused voucher numbers already present in ledger_entries
-- (ledger-only rows), causing sync_purchase_v11 to DELETE+rewrite ledger → looks like "edit".

BEGIN;

SET search_path = public;

CREATE OR REPLACE FUNCTION public.compat_max_voucher_seq_for_prefix(p_prefix text)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT COALESCE(
        MAX(
            NULLIF(
                regexp_replace(voucher_no, '^' || p_prefix || '0*', ''),
                ''
            )::integer
        ),
        0
    )
    FROM (
        SELECT voucher_no FROM public.purchases WHERE voucher_no LIKE p_prefix || '%'
        UNION ALL
        SELECT voucher_no FROM public.sales WHERE voucher_no LIKE p_prefix || '%'
        UNION ALL
        SELECT voucher_no FROM public.ledger_entries WHERE voucher_no LIKE p_prefix || '%'
    ) combined;
$$;

CREATE OR REPLACE FUNCTION public.post_purchase_transaction(
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
    v_expected_total numeric;
    v_voucher_no text;
    v_prefix text;
    v_seq integer;
BEGIN
    IF NOT public.compat_can_edit_transactions() THEN
        RETURN jsonb_build_object('success', false, 'error', 'permission denied');
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

    PERFORM pg_advisory_xact_lock(hashtext('post_purchase_transaction:' || p_purchase_date::text));

    v_prefix := 'PUR-' || to_char(p_purchase_date, 'YYYYMMDD') || '-';
    v_seq := public.compat_max_voucher_seq_for_prefix(v_prefix) + 1;

    LOOP
        v_voucher_no := v_prefix || lpad(v_seq::text, 3, '0');

        IF EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = v_voucher_no)
           OR EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = v_voucher_no)
        THEN
            v_seq := v_seq + 1;
            CONTINUE;
        END IF;

        BEGIN
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
                v_voucher_no,
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

            EXIT;
        EXCEPTION WHEN unique_violation THEN
            v_seq := v_seq + 1;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'voucher_no', v_voucher_no,
        'message', 'Purchase posted. Existing purchase trigger synced ledger and stock.'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.post_sale_transaction(
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
    v_expected_total numeric;
    v_available_stock numeric := 0;
    v_voucher_no text;
    v_prefix text;
    v_seq integer;
BEGIN
    IF NOT public.compat_can_edit_transactions() THEN
        RETURN jsonb_build_object('success', false, 'error', 'permission denied');
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

    SELECT quantity INTO v_available_stock
    FROM public.inventory
    WHERE fuel_type_id = p_fuel_type_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'stock record not found for selected fuel type');
    END IF;

    IF COALESCE(v_available_stock, 0) < p_quantity THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'insufficient stock',
            'available_stock', COALESCE(v_available_stock, 0),
            'requested_quantity', p_quantity
        );
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('post_sale_transaction:' || p_sale_date::text));

    v_prefix := 'SAL-' || to_char(p_sale_date, 'YYYYMMDD') || '-';
    v_seq := public.compat_max_voucher_seq_for_prefix(v_prefix) + 1;

    LOOP
        v_voucher_no := v_prefix || lpad(v_seq::text, 3, '0');

        IF EXISTS (SELECT 1 FROM public.sales WHERE voucher_no = v_voucher_no)
           OR EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = v_voucher_no)
        THEN
            v_seq := v_seq + 1;
            CONTINUE;
        END IF;

        BEGIN
            INSERT INTO public.sales (
                voucher_no,
                sale_date,
                party_id,
                fuel_type_id,
                quantity,
                rate_per_unit,
                total_amount,
                is_credit,
                notes,
                created_by
            )
            VALUES (
                v_voucher_no,
                p_sale_date,
                p_party_id,
                p_fuel_type_id,
                p_quantity,
                p_rate_per_unit,
                p_total_amount,
                COALESCE(p_is_credit, true),
                p_notes,
                auth.uid()
            );

            EXIT;
        EXCEPTION WHEN unique_violation THEN
            v_seq := v_seq + 1;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'voucher_no', v_voucher_no,
        'message', 'Sale posted. Existing sale trigger synced ledger and stock.'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.compat_max_voucher_seq_for_prefix(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.post_purchase_transaction(date, uuid, uuid, numeric, numeric, numeric, boolean, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.post_sale_transaction(date, uuid, uuid, numeric, numeric, numeric, boolean, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

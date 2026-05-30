-- Phase 1: block edit/delete RPCs and direct table mutations from authenticated clients.
-- Creation (post_*, INSERT triggers) remains unchanged.

BEGIN;

SET search_path = public;

CREATE OR REPLACE FUNCTION public.phase1_edit_delete_blocked()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
        'success', false,
        'error', 'Edit/delete temporarily disabled'
    );
$$;

-- ── Edit / upsert / cancel / delete / reverse RPC stubs ─────────────────────

CREATE OR REPLACE FUNCTION public.edit_sale_transaction(
    p_original_voucher_no text,
    p_sale_date date,
    p_party_id uuid,
    p_fuel_type_id uuid,
    p_quantity numeric,
    p_rate_per_unit numeric,
    p_total_amount numeric,
    p_is_credit boolean DEFAULT false,
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.phase1_edit_delete_blocked();
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
BEGIN
    RETURN public.phase1_edit_delete_blocked();
END;
$$;

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
BEGIN
    RETURN public.phase1_edit_delete_blocked();
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_sale_transaction(
    p_voucher_no text,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.phase1_edit_delete_blocked();
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_purchase_transaction(
    p_voucher_no text,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.phase1_edit_delete_blocked();
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_transaction_safely(
    p_voucher_no text,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.phase1_edit_delete_blocked();
END;
$$;

CREATE OR REPLACE FUNCTION public.reverse_transaction_safely(
    p_voucher_no text,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.phase1_edit_delete_blocked();
END;
$$;

-- Legacy reversal RPC (original return type is json, not jsonb — must DROP first)
DROP FUNCTION IF EXISTS public.reverse_transaction(text, text);

CREATE OR REPLACE FUNCTION public.reverse_transaction(
    p_voucher_no text,
    p_reason text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.phase1_edit_delete_blocked()::json;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reverse_transaction(text, text) TO authenticated;

-- Optional: block direct client UPDATE/DELETE on core transaction tables
REVOKE UPDATE, DELETE ON public.sales FROM authenticated;
REVOKE UPDATE, DELETE ON public.purchases FROM authenticated;
REVOKE UPDATE, DELETE ON public.ledger_entries FROM authenticated;

COMMIT;

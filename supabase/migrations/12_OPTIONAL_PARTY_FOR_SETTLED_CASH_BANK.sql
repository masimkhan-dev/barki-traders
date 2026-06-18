-- ============================================================================
-- 12_OPTIONAL_PARTY_FOR_SETTLED_CASH_BANK.sql
-- Phase 2: Cash/Bank sale and purchase can be posted without a party reference.
-- Credit flow remains unchanged in the frontend and existing direct inserts.
-- ============================================================================

BEGIN;

SET search_path = public;

ALTER TABLE public.transaction_settlements
  ALTER COLUMN party_id DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.post_settled_sale(
  p_sale_date DATE,
  p_party_id UUID,
  p_fuel_type_id UUID,
  p_quantity NUMERIC,
  p_rate_per_unit NUMERIC,
  p_payment_mode TEXT,
  p_payment_account_id UUID,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sale_voucher_no TEXT;
  v_settlement_voucher_no TEXT;
  v_total NUMERIC;
  v_ar_id UUID;
  v_payment_account_id UUID;
  v_source_ar_entry_id UUID;
  v_settlement_debit_entry_id UUID;
  v_settlement_credit_entry_id UUID;
  v_party_name TEXT := 'Walk-in Customer';
BEGIN
  IF p_fuel_type_id IS NULL THEN
    RAISE EXCEPTION 'Fuel type is required.';
  END IF;
  IF p_quantity <= 0 OR p_rate_per_unit <= 0 THEN
    RAISE EXCEPTION 'Quantity and rate must be greater than zero.';
  END IF;

  v_payment_account_id := public.validate_settlement_account(p_payment_mode, p_payment_account_id);
  v_total := ROUND(p_quantity * p_rate_per_unit, 2);

  SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
  IF v_ar_id IS NULL THEN
    SELECT id INTO v_ar_id FROM public.accounts WHERE code = '1100';
  END IF;
  IF v_ar_id IS NULL THEN
    RAISE EXCEPTION 'Accounts Receivable control account missing.';
  END IF;

  IF p_party_id IS NOT NULL THEN
    SELECT name INTO v_party_name FROM public.parties WHERE id = p_party_id AND is_active = true;
    IF v_party_name IS NULL THEN
      RAISE EXCEPTION 'Active customer not found.';
    END IF;
  END IF;

  v_sale_voucher_no := public.get_next_voucher_no('SAL', p_sale_date);

  INSERT INTO public.sales (
    voucher_no, sale_date, party_id, fuel_type_id, quantity,
    rate_per_unit, total_amount, is_credit, notes, created_by
  )
  VALUES (
    v_sale_voucher_no, p_sale_date, p_party_id, p_fuel_type_id, p_quantity,
    p_rate_per_unit, v_total, false, p_notes, auth.uid()
  );

  SELECT le.id
  INTO v_source_ar_entry_id
  FROM public.ledger_entries le
  WHERE le.voucher_no = v_sale_voucher_no
    AND le.account_id = v_ar_id
    AND le.party_id IS NOT DISTINCT FROM p_party_id
    AND le.debit_amount = v_total
  ORDER BY le.created_at DESC
  LIMIT 1;

  IF v_source_ar_entry_id IS NULL THEN
    RAISE EXCEPTION 'Sale AR ledger line was not created.';
  END IF;

  v_settlement_voucher_no := public.get_next_voucher_no('SET', p_sale_date);

  INSERT INTO public.ledger_entries (
    voucher_no, voucher_type, posting_date, account_id, party_id,
    debit_amount, credit_amount, narration, created_by
  )
  VALUES (
    v_settlement_voucher_no, 'receipt', p_sale_date, v_payment_account_id, NULL,
    v_total, 0, 'Auto settlement for ' || v_sale_voucher_no || ' (' || p_payment_mode || ')', auth.uid()
  )
  RETURNING id INTO v_settlement_debit_entry_id;

  INSERT INTO public.ledger_entries (
    voucher_no, voucher_type, posting_date, account_id, party_id,
    debit_amount, credit_amount, narration, created_by
  )
  VALUES (
    v_settlement_voucher_no, 'receipt', p_sale_date, v_ar_id, p_party_id,
    0, v_total, 'Auto settlement for ' || v_sale_voucher_no || ' - ' || v_party_name, auth.uid()
  )
  RETURNING id INTO v_settlement_credit_entry_id;

  INSERT INTO public.transaction_settlements (
    source_voucher_no, source_voucher_type, settlement_voucher_no, settlement_voucher_type,
    payment_mode, settlement_account_id, party_id, amount,
    source_control_ledger_entry_id, settlement_debit_ledger_entry_id,
    settlement_credit_ledger_entry_id, created_by
  )
  VALUES (
    v_sale_voucher_no, 'sale', v_settlement_voucher_no, 'receipt',
    p_payment_mode, v_payment_account_id, p_party_id, v_total,
    v_source_ar_entry_id, v_settlement_debit_entry_id,
    v_settlement_credit_entry_id, auth.uid()
  );

  RETURN jsonb_build_object(
    'success', true,
    'voucher_no', v_sale_voucher_no,
    'settlement_voucher_no', v_settlement_voucher_no,
    'payment_mode', p_payment_mode,
    'amount', v_total
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.post_settled_purchase(
  p_purchase_date DATE,
  p_party_id UUID,
  p_fuel_type_id UUID,
  p_quantity NUMERIC,
  p_rate_per_unit NUMERIC,
  p_payment_mode TEXT,
  p_payment_account_id UUID,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_purchase_voucher_no TEXT;
  v_settlement_voucher_no TEXT;
  v_total NUMERIC;
  v_ap_id UUID;
  v_payment_account_id UUID;
  v_source_ap_entry_id UUID;
  v_settlement_debit_entry_id UUID;
  v_settlement_credit_entry_id UUID;
  v_party_name TEXT := 'Walk-in Supplier';
BEGIN
  IF p_fuel_type_id IS NULL THEN
    RAISE EXCEPTION 'Fuel type is required.';
  END IF;
  IF p_quantity <= 0 OR p_rate_per_unit <= 0 THEN
    RAISE EXCEPTION 'Quantity and rate must be greater than zero.';
  END IF;

  v_payment_account_id := public.validate_settlement_account(p_payment_mode, p_payment_account_id);
  v_total := ROUND(p_quantity * p_rate_per_unit, 2);

  SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
  IF v_ap_id IS NULL THEN
    SELECT id INTO v_ap_id FROM public.accounts WHERE code = '2100';
  END IF;
  IF v_ap_id IS NULL THEN
    RAISE EXCEPTION 'Accounts Payable control account missing.';
  END IF;

  IF p_party_id IS NOT NULL THEN
    SELECT name INTO v_party_name FROM public.parties WHERE id = p_party_id AND is_active = true;
    IF v_party_name IS NULL THEN
      RAISE EXCEPTION 'Active supplier not found.';
    END IF;
  END IF;

  v_purchase_voucher_no := public.get_next_voucher_no('PUR', p_purchase_date);

  INSERT INTO public.purchases (
    voucher_no, purchase_date, party_id, fuel_type_id, quantity,
    rate_per_unit, total_amount, notes, created_by
  )
  VALUES (
    v_purchase_voucher_no, p_purchase_date, p_party_id, p_fuel_type_id, p_quantity,
    p_rate_per_unit, v_total, p_notes, auth.uid()
  );

  SELECT le.id
  INTO v_source_ap_entry_id
  FROM public.ledger_entries le
  WHERE le.voucher_no = v_purchase_voucher_no
    AND le.account_id = v_ap_id
    AND le.party_id IS NOT DISTINCT FROM p_party_id
    AND le.credit_amount = v_total
  ORDER BY le.created_at DESC
  LIMIT 1;

  IF v_source_ap_entry_id IS NULL THEN
    RAISE EXCEPTION 'Purchase AP ledger line was not created.';
  END IF;

  v_settlement_voucher_no := public.get_next_voucher_no('SET', p_purchase_date);

  INSERT INTO public.ledger_entries (
    voucher_no, voucher_type, posting_date, account_id, party_id,
    debit_amount, credit_amount, narration, created_by
  )
  VALUES (
    v_settlement_voucher_no, 'payment', p_purchase_date, v_ap_id, p_party_id,
    v_total, 0, 'Auto settlement for ' || v_purchase_voucher_no || ' - ' || v_party_name, auth.uid()
  )
  RETURNING id INTO v_settlement_debit_entry_id;

  INSERT INTO public.ledger_entries (
    voucher_no, voucher_type, posting_date, account_id, party_id,
    debit_amount, credit_amount, narration, created_by
  )
  VALUES (
    v_settlement_voucher_no, 'payment', p_purchase_date, v_payment_account_id, NULL,
    0, v_total, 'Auto settlement for ' || v_purchase_voucher_no || ' (' || p_payment_mode || ')', auth.uid()
  )
  RETURNING id INTO v_settlement_credit_entry_id;

  INSERT INTO public.transaction_settlements (
    source_voucher_no, source_voucher_type, settlement_voucher_no, settlement_voucher_type,
    payment_mode, settlement_account_id, party_id, amount,
    source_control_ledger_entry_id, settlement_debit_ledger_entry_id,
    settlement_credit_ledger_entry_id, created_by
  )
  VALUES (
    v_purchase_voucher_no, 'purchase', v_settlement_voucher_no, 'payment',
    p_payment_mode, v_payment_account_id, p_party_id, v_total,
    v_source_ap_entry_id, v_settlement_debit_entry_id,
    v_settlement_credit_entry_id, auth.uid()
  );

  RETURN jsonb_build_object(
    'success', true,
    'voucher_no', v_purchase_voucher_no,
    'settlement_voucher_no', v_settlement_voucher_no,
    'payment_mode', p_payment_mode,
    'amount', v_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.post_settled_sale(DATE, UUID, UUID, NUMERIC, NUMERIC, TEXT, UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.post_settled_purchase(DATE, UUID, UUID, NUMERIC, NUMERIC, TEXT, UUID, TEXT) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;

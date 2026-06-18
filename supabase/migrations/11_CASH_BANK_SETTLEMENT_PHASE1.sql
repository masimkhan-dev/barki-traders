-- =============================================================================
-- PHASE 1: Cash/Bank settled sales and purchases
-- =============================================================================
-- Safety scope:
-- - Does not rewrite sale/purchase triggers.
-- - Keeps party_id required at the application flow level.
-- - Adds a settlement layer that clears AR/AP immediately for CASH/BANK mode.
-- - Keeps all posting atomic inside SECURITY DEFINER RPCs.
-- =============================================================================

BEGIN;
SET search_path = public;

CREATE TABLE IF NOT EXISTS public.transaction_settlements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_voucher_no TEXT NOT NULL UNIQUE,
  source_voucher_type TEXT NOT NULL CHECK (source_voucher_type IN ('sale', 'purchase')),
  settlement_voucher_no TEXT NOT NULL UNIQUE,
  settlement_voucher_type TEXT NOT NULL CHECK (settlement_voucher_type IN ('receipt', 'payment')),
  payment_mode TEXT NOT NULL CHECK (payment_mode IN ('CASH', 'BANK')),
  settlement_account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
  party_id UUID NOT NULL REFERENCES public.parties(id) ON DELETE RESTRICT,
  amount NUMERIC(15, 2) NOT NULL CHECK (amount > 0),
  source_control_ledger_entry_id UUID REFERENCES public.ledger_entries(id) ON DELETE RESTRICT,
  settlement_debit_ledger_entry_id UUID REFERENCES public.ledger_entries(id) ON DELETE RESTRICT,
  settlement_credit_ledger_entry_id UUID REFERENCES public.ledger_entries(id) ON DELETE RESTRICT,
  reversed_at TIMESTAMPTZ,
  reversal_voucher_no TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_transaction_settlements_source
  ON public.transaction_settlements(source_voucher_no);

CREATE INDEX IF NOT EXISTS idx_transaction_settlements_settlement
  ON public.transaction_settlements(settlement_voucher_no);

ALTER TABLE public.transaction_settlements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS transaction_settlements_select_authenticated ON public.transaction_settlements;
DROP POLICY IF EXISTS transaction_settlements_insert_authenticated ON public.transaction_settlements;
DROP POLICY IF EXISTS transaction_settlements_update_authenticated ON public.transaction_settlements;
DROP POLICY IF EXISTS transaction_settlements_delete_admin_only ON public.transaction_settlements;

CREATE POLICY transaction_settlements_select_authenticated
  ON public.transaction_settlements FOR SELECT TO authenticated USING (true);

CREATE POLICY transaction_settlements_insert_authenticated
  ON public.transaction_settlements FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY transaction_settlements_update_authenticated
  ON public.transaction_settlements FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY transaction_settlements_delete_admin_only
  ON public.transaction_settlements FOR DELETE TO authenticated USING (public.is_admin());

CREATE OR REPLACE FUNCTION public.prevent_transaction_settlement_link_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.source_voucher_no IS DISTINCT FROM OLD.source_voucher_no
     OR NEW.source_voucher_type IS DISTINCT FROM OLD.source_voucher_type
     OR NEW.settlement_voucher_no IS DISTINCT FROM OLD.settlement_voucher_no
     OR NEW.settlement_voucher_type IS DISTINCT FROM OLD.settlement_voucher_type
     OR NEW.payment_mode IS DISTINCT FROM OLD.payment_mode
     OR NEW.settlement_account_id IS DISTINCT FROM OLD.settlement_account_id
     OR NEW.party_id IS DISTINCT FROM OLD.party_id
     OR NEW.amount IS DISTINCT FROM OLD.amount
     OR NEW.source_control_ledger_entry_id IS DISTINCT FROM OLD.source_control_ledger_entry_id
     OR NEW.settlement_debit_ledger_entry_id IS DISTINCT FROM OLD.settlement_debit_ledger_entry_id
     OR NEW.settlement_credit_ledger_entry_id IS DISTINCT FROM OLD.settlement_credit_ledger_entry_id THEN
    RAISE EXCEPTION 'Settlement audit link is immutable.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_transaction_settlement_link_mutation ON public.transaction_settlements;
CREATE TRIGGER trg_prevent_transaction_settlement_link_mutation
  BEFORE UPDATE ON public.transaction_settlements
  FOR EACH ROW EXECUTE FUNCTION public.prevent_transaction_settlement_link_mutation();

CREATE OR REPLACE FUNCTION public.validate_settlement_account(
  p_payment_mode TEXT,
  p_account_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id UUID;
BEGIN
  IF p_payment_mode NOT IN ('CASH', 'BANK') THEN
    RAISE EXCEPTION 'Payment mode must be CASH or BANK.';
  END IF;

  SELECT a.id
  INTO v_account_id
  FROM public.accounts a
  WHERE a.id = p_account_id
    AND a.is_active = true
    AND a.account_type = 'asset'
    AND (
      lower(COALESCE(a.slug, '')) = lower(p_payment_mode)
      OR lower(COALESCE(a.sub_category, '')) = lower(p_payment_mode)
      OR (p_payment_mode = 'CASH' AND lower(a.name) LIKE '%cash%')
      OR (p_payment_mode = 'BANK' AND lower(a.name) LIKE '%bank%')
    );

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Selected account is not a valid active % account.', p_payment_mode;
  END IF;

  RETURN v_account_id;
END;
$$;

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
  v_party_name TEXT;
BEGIN
  IF p_party_id IS NULL THEN
    RAISE EXCEPTION 'Customer is required.';
  END IF;
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

  SELECT name INTO v_party_name FROM public.parties WHERE id = p_party_id AND is_active = true;
  IF v_party_name IS NULL THEN
    RAISE EXCEPTION 'Active customer not found.';
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
    AND le.party_id = p_party_id
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
  v_party_name TEXT;
BEGIN
  IF p_party_id IS NULL THEN
    RAISE EXCEPTION 'Supplier is required.';
  END IF;
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

  SELECT name INTO v_party_name FROM public.parties WHERE id = p_party_id AND is_active = true;
  IF v_party_name IS NULL THEN
    RAISE EXCEPTION 'Active supplier not found.';
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
    AND le.party_id = p_party_id
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

CREATE OR REPLACE FUNCTION public.reverse_transaction(p_voucher_no TEXT, p_reason TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_vno TEXT := 'REV-' || p_voucher_no;
  v_settlement_reverse_vno TEXT;
  v_sale public.sales%ROWTYPE;
  v_purchase public.purchases%ROWTYPE;
  v_settlement public.transaction_settlements%ROWTYPE;
BEGIN
  IF EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = v_new_vno) THEN
    RAISE EXCEPTION 'Voucher % is already reversed.', p_voucher_no;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.transaction_settlements
    WHERE settlement_voucher_no = p_voucher_no
      AND source_voucher_no <> p_voucher_no
  ) THEN
    RAISE EXCEPTION 'Reverse the source voucher instead of reversing its settlement voucher directly.';
  END IF;

  SELECT * INTO v_sale
  FROM public.sales
  WHERE voucher_no = p_voucher_no
    AND is_reversed = false;

  IF FOUND THEN
    PERFORM public.update_stock_quantity(v_sale.fuel_type_id, v_sale.quantity, 'IN');
    UPDATE public.sales SET is_reversed = true WHERE id = v_sale.id;
  ELSE
    SELECT * INTO v_purchase
    FROM public.purchases
    WHERE voucher_no = p_voucher_no
      AND is_reversed = false;

    IF FOUND THEN
      PERFORM public.update_stock_quantity(v_purchase.fuel_type_id, v_purchase.quantity, 'OUT');
      UPDATE public.purchases SET is_reversed = true WHERE id = v_purchase.id;
    ELSE
      RAISE EXCEPTION 'Voucher % not found or already reversed.', p_voucher_no;
    END IF;
  END IF;

  INSERT INTO public.ledger_entries (
    voucher_no, voucher_type, posting_date, account_id, party_id,
    debit_amount, credit_amount, narration, quantity, rate, created_by
  )
  SELECT v_new_vno, voucher_type, CURRENT_DATE, account_id, party_id,
         credit_amount, debit_amount,
         'REVERSAL of ' || p_voucher_no || ': ' || COALESCE(p_reason, ''),
         quantity, rate, auth.uid()
  FROM public.ledger_entries
  WHERE voucher_no = p_voucher_no;

  SELECT * INTO v_settlement
  FROM public.transaction_settlements
  WHERE source_voucher_no = p_voucher_no
    AND reversed_at IS NULL;

  IF FOUND THEN
    v_settlement_reverse_vno := 'REV-' || v_settlement.settlement_voucher_no;

    IF EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = v_settlement_reverse_vno) THEN
      RAISE EXCEPTION 'Settlement voucher % is already reversed.', v_settlement.settlement_voucher_no;
    END IF;

    INSERT INTO public.ledger_entries (
      voucher_no, voucher_type, posting_date, account_id, party_id,
      debit_amount, credit_amount, narration, quantity, rate, created_by
    )
    SELECT v_settlement_reverse_vno, voucher_type, CURRENT_DATE, account_id, party_id,
           credit_amount, debit_amount,
           'REVERSAL of settlement ' || v_settlement.settlement_voucher_no || ': ' || COALESCE(p_reason, ''),
           quantity, rate, auth.uid()
    FROM public.ledger_entries
    WHERE voucher_no = v_settlement.settlement_voucher_no;

    UPDATE public.transaction_settlements
    SET reversed_at = now(),
        reversal_voucher_no = v_settlement_reverse_vno
    WHERE id = v_settlement.id;
  END IF;

  RETURN json_build_object(
    'success', true,
    'reversal_voucher', v_new_vno,
    'settlement_reversal_voucher', v_settlement_reverse_vno
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.validate_settlement_account(TEXT, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.post_settled_sale(DATE, UUID, UUID, NUMERIC, NUMERIC, TEXT, UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.post_settled_purchase(DATE, UUID, UUID, NUMERIC, NUMERIC, TEXT, UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reverse_transaction(TEXT, TEXT) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;

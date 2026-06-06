-- =============================================================================
-- ENABLE VOUCHER FACTORY: transfers, expenses, shrinkage, assets, withdrawals
-- =============================================================================
-- Run after 02_FIX_PARTY_OPENING_BALANCE_DOUBLE_COUNT.sql.
-- =============================================================================

BEGIN;
SET search_path = public;

CREATE OR REPLACE FUNCTION public.create_manage_transaction(
  p_transaction_type TEXT,
  p_from_type TEXT,
  p_from_entity_id UUID,
  p_to_type TEXT,
  p_to_entity_id UUID,
  p_amount NUMERIC,
  p_narration TEXT,
  p_transaction_date DATE
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_voucher_no TEXT;
  v_debit_account_id UUID;
  v_credit_account_id UUID;
  v_ar_id UUID;
  v_ap_id UUID;
  v_from_party_type TEXT;
  v_to_party_type TEXT;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero.';
  END IF;

  IF p_from_entity_id = p_to_entity_id THEN
    RAISE EXCEPTION 'Sender and receiver cannot be the same.';
  END IF;

  SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
  SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
  IF v_ar_id IS NULL OR v_ap_id IS NULL THEN
    RAISE EXCEPTION 'Missing AR/AP control accounts.';
  END IF;

  IF p_from_type = 'account' THEN
    v_credit_account_id := p_from_entity_id;
  ELSE
    SELECT type INTO v_from_party_type FROM public.parties WHERE id = p_from_entity_id;
    v_credit_account_id := CASE WHEN v_from_party_type = 'supplier' THEN v_ap_id ELSE v_ar_id END;
  END IF;

  IF p_to_type = 'account' THEN
    v_debit_account_id := p_to_entity_id;
  ELSE
    SELECT type INTO v_to_party_type FROM public.parties WHERE id = p_to_entity_id;
    v_debit_account_id := CASE WHEN v_to_party_type = 'supplier' THEN v_ap_id ELSE v_ar_id END;
  END IF;

  IF v_debit_account_id IS NULL OR v_credit_account_id IS NULL THEN
    RAISE EXCEPTION 'Could not resolve sender/receiver ledger accounts.';
  END IF;

  v_voucher_no := public.get_next_voucher_no('TRF', p_transaction_date);

  INSERT INTO public.ledger_entries (
    voucher_no, voucher_type, posting_date, account_id, party_id,
    debit_amount, credit_amount, narration, created_by
  )
  VALUES
    (v_voucher_no, 'transfer', p_transaction_date, v_debit_account_id,
     CASE WHEN p_to_type = 'party' THEN p_to_entity_id ELSE NULL END,
     p_amount, 0, COALESCE(p_narration, 'Money movement'), auth.uid()),
    (v_voucher_no, 'transfer', p_transaction_date, v_credit_account_id,
     CASE WHEN p_from_type = 'party' THEN p_from_entity_id ELSE NULL END,
     0, p_amount, COALESCE(p_narration, 'Money movement'), auth.uid());

  RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END;
$$;

CREATE OR REPLACE FUNCTION public.post_expense_entry(
  p_expense_account_id UUID,
  p_payment_account_id UUID,
  p_amount NUMERIC,
  p_narration TEXT,
  p_date DATE,
  p_voucher_no TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_voucher_no TEXT;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero.';
  END IF;
  IF p_expense_account_id IS NULL OR p_payment_account_id IS NULL THEN
    RAISE EXCEPTION 'Expense account and payment source are required.';
  END IF;

  v_voucher_no := COALESCE(p_voucher_no, public.get_next_voucher_no('EXP', p_date));

  INSERT INTO public.ledger_entries (
    voucher_no, voucher_type, posting_date, account_id,
    debit_amount, credit_amount, narration, created_by
  )
  VALUES
    (v_voucher_no, 'expense', p_date, p_expense_account_id, p_amount, 0, COALESCE(p_narration, 'Expense'), auth.uid()),
    (v_voucher_no, 'expense', p_date, p_payment_account_id, 0, p_amount, COALESCE(p_narration, 'Expense payment'), auth.uid());

  RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END;
$$;

CREATE OR REPLACE FUNCTION public.post_fuel_shrinkage_writeoff(
  p_fuel_type_id UUID,
  p_quantity_lost NUMERIC,
  p_rate_per_liter NUMERIC,
  p_date DATE,
  p_reason TEXT DEFAULT 'Tanker Delivery Shortage',
  p_voucher_no TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_voucher_no TEXT;
  v_amount NUMERIC;
  v_inventory_acc_id UUID;
  v_loss_acc_id UUID;
  v_current_stock NUMERIC;
BEGIN
  IF p_quantity_lost <= 0 THEN
    RAISE EXCEPTION 'Quantity lost must be greater than zero.';
  END IF;
  IF p_rate_per_liter <= 0 THEN
    RAISE EXCEPTION 'Rate per liter must be greater than zero.';
  END IF;

  SELECT id INTO v_inventory_acc_id FROM public.accounts WHERE slug = 'inventory';
  SELECT id INTO v_loss_acc_id FROM public.accounts WHERE slug = 'fuel_loss';
  IF v_inventory_acc_id IS NULL OR v_loss_acc_id IS NULL THEN
    RAISE EXCEPTION 'Missing inventory or fuel loss account.';
  END IF;

  SELECT quantity INTO v_current_stock
  FROM public.inventory
  WHERE fuel_type_id = p_fuel_type_id
  FOR UPDATE;

  IF v_current_stock IS NULL THEN
    RAISE EXCEPTION 'Fuel type not found in inventory.';
  END IF;
  IF v_current_stock < p_quantity_lost THEN
    RAISE EXCEPTION 'Cannot record shrinkage of %. Current stock is only %.', p_quantity_lost, v_current_stock;
  END IF;

  v_amount := round(p_quantity_lost * p_rate_per_liter, 2);
  v_voucher_no := COALESCE(p_voucher_no, public.get_next_voucher_no('SHR', p_date));

  INSERT INTO public.ledger_entries (
    voucher_no, voucher_type, posting_date, account_id,
    debit_amount, credit_amount, narration, quantity, rate, created_by
  )
  VALUES
    (v_voucher_no, 'shrinkage', p_date, v_loss_acc_id, v_amount, 0,
     'SHRINKAGE: ' || COALESCE(p_reason, ''), p_quantity_lost, p_rate_per_liter, auth.uid()),
    (v_voucher_no, 'shrinkage', p_date, v_inventory_acc_id, 0, v_amount,
     'SHRINKAGE: ' || COALESCE(p_reason, ''), p_quantity_lost, p_rate_per_liter, auth.uid());

  UPDATE public.inventory
  SET quantity = quantity - p_quantity_lost,
      last_updated = now()
  WHERE fuel_type_id = p_fuel_type_id;

  INSERT INTO public.inventory_events (
    fuel_type_id, voucher_no, event_type, quantity, unit_cost, total_cost, avg_cost_after, stock_after, narration
  )
  VALUES (
    p_fuel_type_id, v_voucher_no, 'ADJUSTMENT', -p_quantity_lost, p_rate_per_liter, -v_amount,
    p_rate_per_liter, v_current_stock - p_quantity_lost, p_reason
  );

  RETURN v_voucher_no;
END;
$$;

CREATE OR REPLACE FUNCTION public.purchase_fixed_asset(
  p_name TEXT,
  p_category TEXT,
  p_amount NUMERIC,
  p_date DATE,
  p_paid_from_account_id UUID,
  p_description TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_asset_account_id UUID;
  v_voucher_no TEXT;
  v_new_code TEXT;
  v_max_code INT;
BEGIN
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'Asset name is required.';
  END IF;
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Asset amount must be greater than zero.';
  END IF;
  IF p_paid_from_account_id IS NULL THEN
    RAISE EXCEPTION 'Payment source is required.';
  END IF;

  SELECT COALESCE(MAX(NULLIF(regexp_replace(code, '\D', '', 'g'), '')::INT), 1500)
  INTO v_max_code
  FROM public.accounts
  WHERE account_type = 'asset';

  v_new_code := (v_max_code + 1)::TEXT;

  INSERT INTO public.accounts (name, code, account_type, sub_category, is_active, is_system)
  VALUES (p_name, v_new_code, 'asset', 'fixed_asset', true, false)
  RETURNING id INTO v_asset_account_id;

  INSERT INTO public.fixed_assets (name, description, category, purchase_date, purchase_cost, created_by)
  VALUES (p_name, p_description, COALESCE(p_category, 'Other'), p_date, p_amount, auth.uid());

  v_voucher_no := public.get_next_voucher_no('AST', p_date);

  INSERT INTO public.ledger_entries (
    voucher_no, voucher_type, posting_date, account_id,
    debit_amount, credit_amount, narration, created_by
  )
  VALUES
    (v_voucher_no, 'asset', p_date, v_asset_account_id, p_amount, 0, COALESCE(p_description, 'Fixed asset purchase'), auth.uid()),
    (v_voucher_no, 'asset', p_date, p_paid_from_account_id, 0, p_amount, COALESCE(p_description, 'Fixed asset payment'), auth.uid());

  RETURN jsonb_build_object('success', true, 'voucher_no', v_voucher_no, 'asset_account_id', v_asset_account_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.post_owner_withdrawal(
  p_payment_account_id UUID,
  p_amount NUMERIC,
  p_narration TEXT,
  p_date DATE
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_voucher_no TEXT;
  v_drawings_id UUID;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Withdrawal amount must be greater than zero.';
  END IF;
  IF p_payment_account_id IS NULL THEN
    RAISE EXCEPTION 'Payment source is required.';
  END IF;

  SELECT id INTO v_drawings_id FROM public.accounts WHERE slug = 'owner_drawings';
  IF v_drawings_id IS NULL THEN
    RAISE EXCEPTION 'Owner drawings account missing.';
  END IF;

  v_voucher_no := public.get_next_voucher_no('DRW', p_date);

  INSERT INTO public.ledger_entries (
    voucher_no, voucher_type, posting_date, account_id,
    debit_amount, credit_amount, narration, created_by
  )
  VALUES
    (v_voucher_no, 'withdrawal', p_date, v_drawings_id, p_amount, 0, COALESCE(p_narration, 'Owner withdrawal'), auth.uid()),
    (v_voucher_no, 'withdrawal', p_date, p_payment_account_id, 0, p_amount, COALESCE(p_narration, 'Owner withdrawal'), auth.uid());

  RETURN json_build_object('success', true, 'voucher_no', v_voucher_no, 'amount', p_amount);
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;
NOTIFY pgrst, 'reload schema';

COMMIT;

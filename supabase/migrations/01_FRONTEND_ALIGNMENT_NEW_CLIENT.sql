-- =============================================================================
-- FRONTEND ALIGNMENT PATCH: New Client
-- =============================================================================
-- Run this after 00_MASTER_BASELINE_BARKI_TRADERS.sql on a fresh Supabase DB.
-- Purpose: add the RPC/table contract currently required by the frontend and
-- override risky/stale functions from the old client dump.
-- =============================================================================

BEGIN;
SET search_path = public;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE SEQUENCE IF NOT EXISTS public.global_voucher_seq START 10000;

-- Extra tables/columns used by current reports and admin screens.
CREATE TABLE IF NOT EXISTS public.accounting_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  is_closed BOOLEAN NOT NULL DEFAULT false,
  closed_at TIMESTAMPTZ,
  closed_by UUID
);

CREATE TABLE IF NOT EXISTS public.fiscal_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  period_name TEXT NOT NULL,
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  is_closed BOOLEAN NOT NULL DEFAULT false,
  closed_at TIMESTAMPTZ,
  closed_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.report_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_name TEXT NOT NULL,
  user_id UUID REFERENCES auth.users(id),
  filters JSONB,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ip_address TEXT
);

CREATE TABLE IF NOT EXISTS public.fixed_assets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  category TEXT NOT NULL DEFAULT 'Other',
  purchase_date DATE NOT NULL DEFAULT CURRENT_DATE,
  purchase_cost NUMERIC(15, 2) NOT NULL DEFAULT 0,
  useful_life_years INTEGER NOT NULL DEFAULT 5,
  status TEXT NOT NULL DEFAULT 'Active',
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.inventory_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fuel_type_id UUID REFERENCES public.fuel_types(id),
  voucher_no TEXT NOT NULL,
  event_type TEXT NOT NULL,
  quantity NUMERIC(15, 2) NOT NULL,
  unit_cost NUMERIC(15, 2) NOT NULL DEFAULT 0,
  total_cost NUMERIC(15, 2) NOT NULL DEFAULT 0,
  avg_cost_after NUMERIC(18, 6) NOT NULL DEFAULT 0,
  stock_after NUMERIC(15, 2) NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  narration TEXT
);

ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS slug TEXT,
  ADD COLUMN IF NOT EXISTS sub_category TEXT DEFAULT 'general',
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();

ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS is_paid_now BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS payment_method TEXT NOT NULL DEFAULT 'Cash';

CREATE INDEX IF NOT EXISTS idx_accounts_slug ON public.accounts(slug);
CREATE INDEX IF NOT EXISTS idx_accounts_sub_category ON public.accounts(sub_category);
CREATE INDEX IF NOT EXISTS idx_inventory_events_fuel_date ON public.inventory_events(fuel_type_id, created_at);

-- Required system accounts. Slugs are the stable API between SQL and frontend.
INSERT INTO public.accounts (code, name, account_type, slug, sub_category, is_system, is_active)
VALUES
  ('1000', 'Cash on Hand', 'asset', 'cash', 'cash', true, true),
  ('1010', 'Bank Account', 'asset', 'bank', 'bank', true, true),
  ('1100', 'Accounts Receivable (Control)', 'asset', 'ar', 'trade_receivable', true, true),
  ('1200', 'Inventory (Control)', 'asset', 'inventory', 'inventory', true, true),
  ('2100', 'Accounts Payable (Control)', 'liability', 'ap', 'trade_payable', true, true),
  ('3000', 'Owner''s Capital', 'equity', 'capital', 'capital', true, true),
  ('3010', 'Owner Drawings', 'equity', 'owner_drawings', 'drawings', true, true),
  ('3999', 'P&L Closing Adjustment', 'equity', 'retained-earnings', 'closing', true, true),
  ('4000', 'Sales Revenue', 'income', 'sales_revenue', 'sales', true, true),
  ('4100', 'Cost of Goods Sold', 'expense', 'cogs', 'cost_of_sales', true, true),
  ('5000', 'Fuel Loss / Shrinkage', 'expense', 'fuel_loss', 'operating_expense', true, true),
  ('6000', 'Operating Expenses', 'expense', 'operating_expenses', 'operating_expense', true, true)
ON CONFLICT (code) DO UPDATE
SET slug = COALESCE(public.accounts.slug, EXCLUDED.slug),
    sub_category = COALESCE(public.accounts.sub_category, EXCLUDED.sub_category),
    is_system = EXCLUDED.is_system,
    is_active = EXCLUDED.is_active;

-- Make sure every fuel type has a stock cache row.
INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost)
SELECT id, 0, 0 FROM public.fuel_types
ON CONFLICT (fuel_type_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Core compatibility helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_next_voucher_no(p_prefix TEXT, p_date DATE DEFAULT CURRENT_DATE)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_seq BIGINT;
BEGIN
  v_seq := nextval('public.global_voucher_seq');
  RETURN p_prefix || '-' || to_char(COALESCE(p_date, CURRENT_DATE), 'YYYYMMDD') || '-' || lpad(v_seq::TEXT, 6, '0');
END;
$$;

CREATE OR REPLACE FUNCTION public.create_secure_account_v1(
  p_name TEXT,
  p_type TEXT,
  p_sub_category TEXT,
  p_opening_balance NUMERIC DEFAULT 0,
  p_user_id UUID DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id UUID;
  v_equity_id UUID;
  v_code_prefix TEXT;
  v_max_code INT;
  v_new_code TEXT;
  v_voucher TEXT;
BEGIN
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'Account name is required.';
  END IF;

  v_code_prefix := CASE p_type
    WHEN 'asset' THEN '1'
    WHEN 'liability' THEN '2'
    WHEN 'equity' THEN '3'
    WHEN 'income' THEN '4'
    ELSE '5'
  END;

  SELECT COALESCE(MAX(NULLIF(regexp_replace(code, '\D', '', 'g'), '')::INT), (v_code_prefix || '000')::INT)
  INTO v_max_code
  FROM public.accounts
  WHERE code LIKE v_code_prefix || '%';

  v_new_code := (v_max_code + 1)::TEXT;

  INSERT INTO public.accounts (name, code, account_type, sub_category, is_active, is_system)
  VALUES (p_name, v_new_code, p_type, COALESCE(p_sub_category, 'general'), true, false)
  RETURNING id INTO v_account_id;

  IF COALESCE(p_opening_balance, 0) <> 0 THEN
    SELECT id INTO v_equity_id FROM public.accounts WHERE slug = 'capital' LIMIT 1;
    IF v_equity_id IS NULL THEN
      RAISE EXCEPTION 'Capital account missing.';
    END IF;

    v_voucher := public.get_next_voucher_no('OPEN-ACC', CURRENT_DATE);
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES
      (v_voucher, 'opening', CURRENT_DATE, v_account_id,
       CASE WHEN p_opening_balance > 0 THEN p_opening_balance ELSE 0 END,
       CASE WHEN p_opening_balance < 0 THEN abs(p_opening_balance) ELSE 0 END,
       'Opening Balance Initialization: ' || p_name, COALESCE(p_user_id, auth.uid())),
      (v_voucher, 'opening', CURRENT_DATE, v_equity_id,
       CASE WHEN p_opening_balance < 0 THEN abs(p_opening_balance) ELSE 0 END,
       CASE WHEN p_opening_balance > 0 THEN p_opening_balance ELSE 0 END,
       'Equity Offset for ' || p_name, COALESCE(p_user_id, auth.uid()));
  END IF;

  RETURN json_build_object('success', true, 'account_id', v_account_id, 'code', v_new_code);
END;
$$;

-- Frontend currently sends p_amount and p_date.
CREATE OR REPLACE FUNCTION public.initialize_party_opening_balance(
  p_party_id UUID,
  p_amount NUMERIC,
  p_date DATE DEFAULT CURRENT_DATE
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ar_id UUID;
  v_ap_id UUID;
  v_capital_id UUID;
  v_party_name TEXT;
  v_voucher TEXT;
BEGIN
  IF COALESCE(p_amount, 0) = 0 THEN
    RETURN 'SKIP: Zero opening balance';
  END IF;

  SELECT name INTO v_party_name FROM public.parties WHERE id = p_party_id;
  IF v_party_name IS NULL THEN
    RAISE EXCEPTION 'Party not found.';
  END IF;

  SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
  SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
  SELECT id INTO v_capital_id FROM public.accounts WHERE slug = 'capital';

  IF v_ar_id IS NULL OR v_ap_id IS NULL OR v_capital_id IS NULL THEN
    RAISE EXCEPTION 'Missing control accounts: ar/ap/capital.';
  END IF;

  v_voucher := 'OB-' || upper(substring(regexp_replace(v_party_name, '[^A-Za-z0-9]', '', 'g'), 1, 3)) || '-' || substring(p_party_id::TEXT, 1, 8);
  IF EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = v_voucher) THEN
    RETURN 'ERROR: Opening balance already posted for this party';
  END IF;

  IF p_amount > 0 THEN
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES
      (v_voucher, 'opening', p_date, v_ar_id, p_party_id, p_amount, 0, 'Opening Balance - ' || v_party_name || ' (Receivable)', auth.uid()),
      (v_voucher, 'opening', p_date, v_capital_id, NULL, 0, p_amount, 'Opening Balance - ' || v_party_name || ' (Contra)', auth.uid());
  ELSE
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES
      (v_voucher, 'opening', p_date, v_capital_id, NULL, abs(p_amount), 0, 'Opening Balance - ' || v_party_name || ' (Contra)', auth.uid()),
      (v_voucher, 'opening', p_date, v_ap_id, p_party_id, 0, abs(p_amount), 'Opening Balance - ' || v_party_name || ' (Payable)', auth.uid());
  END IF;

  RETURN 'SUCCESS: Posted voucher ' || v_voucher;
END;
$$;

CREATE OR REPLACE FUNCTION public.setup_opening_balances(
  p_cash_amount NUMERIC,
  p_bank_amount NUMERIC,
  p_opening_date DATE
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cash_id UUID;
  v_bank_id UUID;
  v_capital_id UUID;
  v_voucher TEXT;
  v_total NUMERIC := COALESCE(p_cash_amount, 0) + COALESCE(p_bank_amount, 0);
BEGIN
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'Opening total must be greater than zero.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_type = 'opening') THEN
    RAISE EXCEPTION 'Opening balances already exist.';
  END IF;

  SELECT id INTO v_cash_id FROM public.accounts WHERE slug = 'cash';
  SELECT id INTO v_bank_id FROM public.accounts WHERE slug = 'bank';
  SELECT id INTO v_capital_id FROM public.accounts WHERE slug = 'capital';

  IF v_cash_id IS NULL OR v_bank_id IS NULL OR v_capital_id IS NULL THEN
    RAISE EXCEPTION 'Missing cash, bank, or capital account.';
  END IF;

  v_voucher := public.get_next_voucher_no('OPEN', p_opening_date);

  IF COALESCE(p_cash_amount, 0) > 0 THEN
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher, 'opening', p_opening_date, v_cash_id, p_cash_amount, 0, 'Opening Cash Balance', auth.uid());
  END IF;

  IF COALESCE(p_bank_amount, 0) > 0 THEN
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher, 'opening', p_opening_date, v_bank_id, p_bank_amount, 0, 'Opening Bank Balance', auth.uid());
  END IF;

  INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, debit_amount, credit_amount, narration, created_by)
  VALUES (v_voucher, 'opening', p_opening_date, v_capital_id, 0, v_total, 'Opening Capital Offset', auth.uid());

  RETURN json_build_object('success', true, 'voucher_no', v_voucher, 'total_capital', v_total);
END;
$$;

-- ---------------------------------------------------------------------------
-- Reporting RPCs used by the frontend
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_dashboard_feed(p_limit INTEGER DEFAULT 20)
RETURNS TABLE(id UUID, date DATE, voucher_no TEXT, party_name TEXT, description TEXT, paid NUMERIC, received NUMERIC, running_balance NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    le.id,
    le.posting_date,
    le.voucher_no,
    p.name,
    le.narration,
    le.debit_amount,
    le.credit_amount,
    COALESCE(p.opening_balance, 0) + (
      SELECT COALESCE(SUM(le2.debit_amount - le2.credit_amount), 0)
      FROM public.ledger_entries le2
      WHERE le2.party_id = le.party_id
        AND (le2.is_reversed = false OR le2.is_reversed IS NULL)
        AND (le2.posting_date < le.posting_date OR (le2.posting_date = le.posting_date AND le2.created_at <= le.created_at))
    )
  FROM public.ledger_entries le
  JOIN public.parties p ON p.id = le.party_id
  WHERE le.is_reversed = false OR le.is_reversed IS NULL
  ORDER BY le.posting_date DESC, le.created_at DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_party_statement(
  p_party_id UUID,
  p_start_date DATE DEFAULT '2000-01-01'::DATE,
  p_end_date DATE DEFAULT '2099-12-31'::DATE
)
RETURNS TABLE(posting_date DATE, voucher_no TEXT, particulars TEXT, details TEXT, contra_mode TEXT, qty NUMERIC, rate NUMERIC, debit NUMERIC, credit NUMERIC, running_balance NUMERIC, fuel_name TEXT, is_reversed_entry BOOLEAN)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_opening NUMERIC := 0;
BEGIN
  SELECT COALESCE(p.opening_balance, 0) + COALESCE((
    SELECT SUM(le.debit_amount - le.credit_amount)
    FROM public.ledger_entries le
    WHERE le.party_id = p_party_id
      AND (le.is_reversed = false OR le.is_reversed IS NULL)
      AND le.posting_date < p_start_date
  ), 0)
  INTO v_opening
  FROM public.parties p
  WHERE p.id = p_party_id;

  RETURN QUERY SELECT p_start_date - 1, 'OPEN'::TEXT, 'Opening Balance'::TEXT, 'B/F'::TEXT, '--'::TEXT,
    NULL::NUMERIC, NULL::NUMERIC,
    CASE WHEN v_opening >= 0 THEN v_opening ELSE 0 END,
    CASE WHEN v_opening < 0 THEN abs(v_opening) ELSE 0 END,
    v_opening, NULL::TEXT, false;

  RETURN QUERY
  WITH aux AS (
    SELECT s.voucher_no, s.quantity, s.rate_per_unit, ft.name
    FROM public.sales s JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
    UNION ALL
    SELECT pu.voucher_no, pu.quantity, pu.rate_per_unit, ft.name
    FROM public.purchases pu JOIN public.fuel_types ft ON ft.id = pu.fuel_type_id
  ),
  entries AS (
    SELECT
      le.posting_date,
      le.voucher_no,
      COALESCE(le.narration, '') AS narration,
      le.voucher_type::TEXT AS details,
      'Cash/Bank'::TEXT AS contra_mode,
      aux.quantity,
      aux.rate_per_unit,
      le.debit_amount,
      le.credit_amount,
      SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at, le.voucher_no) + v_opening AS running_balance,
      aux.name AS fuel_name,
      COALESCE(le.is_reversed, false) AS is_reversed_entry,
      le.created_at
    FROM public.ledger_entries le
    LEFT JOIN aux ON aux.voucher_no = le.voucher_no
    WHERE le.party_id = p_party_id
      AND le.posting_date BETWEEN p_start_date AND p_end_date
  )
  SELECT e.posting_date, e.voucher_no, e.narration, e.details, e.contra_mode, e.quantity, e.rate_per_unit,
         e.debit_amount, e.credit_amount, e.running_balance, e.fuel_name, e.is_reversed_entry
  FROM entries e
  ORDER BY e.posting_date, e.created_at, e.voucher_no;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_party_product_summary(p_party_id UUID, p_start_date DATE DEFAULT '2000-01-01'::DATE, p_end_date DATE DEFAULT '2099-12-31'::DATE)
RETURNS TABLE(fuel_name TEXT, total_qty NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT x.fuel_name, SUM(x.qty)::NUMERIC
  FROM (
    SELECT ft.name AS fuel_name, s.quantity AS qty
    FROM public.sales s JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
    WHERE s.party_id = p_party_id AND s.sale_date BETWEEN p_start_date AND p_end_date AND s.is_reversed = false
    UNION ALL
    SELECT ft.name, pu.quantity
    FROM public.purchases pu JOIN public.fuel_types ft ON ft.id = pu.fuel_type_id
    WHERE pu.party_id = p_party_id AND pu.purchase_date BETWEEN p_start_date AND p_end_date AND pu.is_reversed = false
  ) x
  GROUP BY x.fuel_name
  HAVING SUM(x.qty) <> 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_customer_ledger_statement(target_customer_id UUID)
RETURNS TABLE(entry_id UUID, posting_date DATE, voucher_no TEXT, voucher_type TEXT, narration TEXT, debit_amount NUMERIC, credit_amount NUMERIC, quantity NUMERIC, rate NUMERIC, fuel_type TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT le.id, le.posting_date, le.voucher_no, le.voucher_type, le.narration, le.debit_amount, le.credit_amount,
         s.quantity, s.rate_per_unit, ft.name
  FROM public.ledger_entries le
  LEFT JOIN public.sales s ON s.voucher_no = le.voucher_no
  LEFT JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
  WHERE le.party_id = target_customer_id
    AND (le.is_reversed = false OR le.is_reversed IS NULL)
  ORDER BY le.posting_date, le.created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_supplier_ledger_statement(target_supplier_id UUID)
RETURNS TABLE(entry_id UUID, posting_date DATE, voucher_no TEXT, voucher_type TEXT, narration TEXT, debit_amount NUMERIC, credit_amount NUMERIC, quantity NUMERIC, rate NUMERIC, fuel_type TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT le.id, le.posting_date, le.voucher_no, le.voucher_type, le.narration, le.debit_amount, le.credit_amount,
         pu.quantity, pu.rate_per_unit, ft.name
  FROM public.ledger_entries le
  LEFT JOIN public.purchases pu ON pu.voucher_no = le.voucher_no
  LEFT JOIN public.fuel_types ft ON ft.id = pu.fuel_type_id
  WHERE le.party_id = target_supplier_id
    AND (le.is_reversed = false OR le.is_reversed IS NULL)
  ORDER BY le.posting_date, le.created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_market_position_report(p_as_of_date DATE)
RETURNS TABLE(party_id UUID, party_name TEXT, party_type TEXT, receivable_balance NUMERIC, payable_balance NUMERIC, last_transaction_date DATE)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH balances AS (
    SELECT p.id, p.name, p.type,
           COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0) AS bal,
           MAX(le.posting_date) AS last_tx
    FROM public.parties p
    LEFT JOIN public.ledger_entries le
      ON le.party_id = p.id
     AND le.posting_date <= p_as_of_date
     AND (le.is_reversed = false OR le.is_reversed IS NULL)
    GROUP BY p.id, p.name, p.type, p.opening_balance
  )
  SELECT id, name, type,
         CASE WHEN bal > 0 THEN bal ELSE 0 END,
         CASE WHEN bal < 0 THEN abs(bal) ELSE 0 END,
         last_tx
  FROM balances
  WHERE bal <> 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_payments_report(p_start_date DATE, p_end_date DATE)
RETURNS TABLE(posting_date DATE, voucher_no TEXT, voucher_type TEXT, from_name TEXT, to_name TEXT, amount NUMERIC, narration TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH pairs AS (
    SELECT le.voucher_no, le.posting_date, le.voucher_type, le.narration,
           CASE WHEN le.credit_amount > 0 THEN COALESCE(p.name, a.name) END AS giver,
           CASE WHEN le.debit_amount > 0 THEN COALESCE(p.name, a.name) END AS receiver,
           GREATEST(le.debit_amount, le.credit_amount) AS amt
    FROM public.ledger_entries le
    JOIN public.accounts a ON a.id = le.account_id
    LEFT JOIN public.parties p ON p.id = le.party_id
    WHERE le.voucher_type IN ('receipt', 'payment', 'transfer', 'adjustment', 'journal', 'opening')
      AND (le.is_reversed = false OR le.is_reversed IS NULL)
  )
  SELECT p.posting_date, p.voucher_no, p.voucher_type,
         MAX(p.giver) FILTER (WHERE p.giver IS NOT NULL),
         MAX(p.receiver) FILTER (WHERE p.receiver IS NOT NULL),
         MAX(p.amt), MAX(p.narration)
  FROM pairs p
  WHERE p.posting_date BETWEEN p_start_date AND p_end_date
  GROUP BY p.voucher_no, p.posting_date, p.voucher_type
  ORDER BY p.posting_date DESC, p.voucher_no DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_trial_balance_v2(p_start_date DATE DEFAULT NULL, p_end_date DATE DEFAULT NULL)
RETURNS TABLE(account_code TEXT, account_name TEXT, account_type TEXT, opening_balance NUMERIC, debit_total NUMERIC, credit_total NUMERIC, net_movement NUMERIC, debit_balance NUMERIC, credit_balance NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH all_entities AS (
    SELECT a.id, 'account'::TEXT AS etype, a.code::TEXT AS ac, a.name::TEXT AS an, a.account_type::TEXT AS at, 0::NUMERIC AS ob
    FROM public.accounts a
    WHERE COALESCE(a.slug, '') NOT IN ('ar', 'ap', 'party_control')
    UNION ALL
    SELECT p.id, 'party', (CASE WHEN p.type = 'customer' THEN '1100-' ELSE '2100-' END || left(p.id::TEXT, 8)),
           p.name, (CASE WHEN p.type = 'customer' THEN 'asset' ELSE 'liability' END), p.opening_balance
    FROM public.parties p
  ),
  sums AS (
    SELECT ae.id, ae.etype,
      SUM(CASE WHEN p_start_date IS NOT NULL AND le.posting_date < p_start_date THEN le.debit_amount - le.credit_amount ELSE 0 END) AS post_op,
      SUM(CASE WHEN (p_start_date IS NULL OR le.posting_date >= p_start_date) AND (p_end_date IS NULL OR le.posting_date <= p_end_date) THEN le.debit_amount ELSE 0 END) AS dr,
      SUM(CASE WHEN (p_start_date IS NULL OR le.posting_date >= p_start_date) AND (p_end_date IS NULL OR le.posting_date <= p_end_date) THEN le.credit_amount ELSE 0 END) AS cr
    FROM all_entities ae
    LEFT JOIN public.ledger_entries le
      ON ((ae.etype = 'account' AND le.account_id = ae.id) OR (ae.etype = 'party' AND le.party_id = ae.id))
     AND (le.is_reversed = false OR le.is_reversed IS NULL)
    GROUP BY ae.id, ae.etype
  ),
  results AS (
    SELECT ae.ac, ae.an, ae.at,
           ae.ob + COALESCE(s.post_op, 0) AS op_bal,
           COALESCE(s.dr, 0) AS dr_total,
           COALESCE(s.cr, 0) AS cr_total,
           COALESCE(s.dr, 0) - COALESCE(s.cr, 0) AS movement,
           ae.ob + COALESCE(s.post_op, 0) + COALESCE(s.dr, 0) - COALESCE(s.cr, 0) AS final_bal
    FROM all_entities ae
    LEFT JOIN sums s ON s.id = ae.id AND s.etype = ae.etype
  )
  SELECT ac, an, at, round(op_bal, 2), round(dr_total, 2), round(cr_total, 2), round(movement, 2),
         CASE WHEN final_bal > 0 THEN round(final_bal, 2) ELSE 0 END,
         CASE WHEN final_bal < 0 THEN round(abs(final_bal), 2) ELSE 0 END
  FROM results
  WHERE dr_total <> 0 OR cr_total <> 0 OR op_bal <> 0
  ORDER BY CASE WHEN at = 'asset' THEN 1 WHEN at = 'liability' THEN 2 WHEN at = 'equity' THEN 3 WHEN at = 'income' THEN 4 ELSE 5 END, ac;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_profit_loss_v13(p_start_date DATE, p_end_date DATE)
RETURNS TABLE(section_code TEXT, section_name TEXT, account_name TEXT, amount NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    CASE
      WHEN a.account_type = 'income' THEN '10'
      WHEN a.slug = 'cogs' OR a.code = '4100' THEN '20'
      WHEN a.sub_category = 'operating_expense' THEN '30'
      WHEN a.sub_category = 'utility_bill' THEN '40'
      WHEN a.sub_category = 'salary' THEN '50'
      ELSE '90'
    END,
    CASE
      WHEN a.account_type = 'income' THEN 'Revenue'
      WHEN a.slug = 'cogs' OR a.code = '4100' THEN 'Cost of Sales'
      ELSE initcap(replace(COALESCE(a.sub_category, 'Other Expense'), '_', ' '))
    END,
    a.name::TEXT,
    round(CASE WHEN a.account_type = 'income' THEN SUM(le.credit_amount - le.debit_amount) ELSE SUM(le.debit_amount - le.credit_amount) END, 2)
  FROM public.accounts a
  JOIN public.ledger_entries le ON le.account_id = a.id
  WHERE a.account_type IN ('income', 'expense')
    AND le.posting_date BETWEEN p_start_date AND p_end_date
    AND (le.is_reversed = false OR le.is_reversed IS NULL)
  GROUP BY a.id, a.name, a.account_type, a.sub_category, a.slug, a.code
  HAVING round(CASE WHEN a.account_type = 'income' THEN SUM(le.credit_amount - le.debit_amount) ELSE SUM(le.debit_amount - le.credit_amount) END, 2) <> 0
  ORDER BY 1, 4 DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_profit_loss_v11(p_start_date DATE, p_end_date DATE)
RETURNS TABLE(section TEXT, account_name TEXT, amount NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    CASE WHEN a.account_type = 'income' THEN 'Income'
         WHEN a.slug = 'cogs' OR a.code = '4100' THEN 'Direct Costs'
         ELSE 'Expenses' END,
    a.name::TEXT,
    CASE WHEN a.account_type = 'income' THEN SUM(le.credit_amount - le.debit_amount)
         ELSE SUM(le.debit_amount - le.credit_amount) END
  FROM public.accounts a
  JOIN public.ledger_entries le ON le.account_id = a.id
  WHERE a.account_type IN ('income', 'expense')
    AND le.posting_date BETWEEN p_start_date AND p_end_date
    AND (le.is_reversed = false OR le.is_reversed IS NULL)
  GROUP BY a.name, a.account_type, a.slug, a.code;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_financial_position_v13(p_date DATE)
RETURNS TABLE(section_code TEXT, section_name TEXT, group_name TEXT, account_name TEXT, balance NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_net_profit NUMERIC;
BEGIN
  SELECT COALESCE(SUM(CASE WHEN a.account_type = 'income' THEN le.credit_amount - le.debit_amount ELSE -(le.debit_amount - le.credit_amount) END), 0)
  INTO v_net_profit
  FROM public.accounts a
  JOIN public.ledger_entries le ON le.account_id = a.id
  WHERE a.account_type IN ('income', 'expense')
    AND le.posting_date <= p_date
    AND (le.is_reversed = false OR le.is_reversed IS NULL);

  RETURN QUERY
  WITH balances AS (
    SELECT a.id, a.name, a.account_type, a.sub_category, a.code,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0) AS net_debit
    FROM public.accounts a
    LEFT JOIN public.ledger_entries le
      ON le.account_id = a.id
     AND le.posting_date <= p_date
     AND (le.is_reversed = false OR le.is_reversed IS NULL)
    GROUP BY a.id, a.name, a.account_type, a.sub_category, a.code
  )
  SELECT * FROM (
    SELECT CASE WHEN b.sub_category = 'fixed_asset' THEN '15' ELSE '10' END,
           CASE WHEN b.sub_category = 'fixed_asset' THEN 'Non-Current Assets' ELSE 'Current Assets' END,
           CASE WHEN b.code = '1100' THEN 'Trade Receivables (Lena)' ELSE initcap(replace(COALESCE(b.sub_category, 'general'), '_', ' ')) END,
           b.name::TEXT, b.net_debit
    FROM balances b
    WHERE b.account_type = 'asset' AND (b.net_debit <> 0 OR b.code IN ('1000', '1010'))
    UNION ALL
    SELECT '20', 'Liabilities',
           CASE WHEN b.code = '2100' THEN 'Trade Payables (Dena)' ELSE initcap(replace(COALESCE(b.sub_category, 'general'), '_', ' ')) END,
           b.name::TEXT, -b.net_debit
    FROM balances b WHERE b.account_type = 'liability' AND b.net_debit <> 0
    UNION ALL
    SELECT '30', 'Equity', 'Capital & Ownership', b.name::TEXT, -b.net_debit
    FROM balances b WHERE b.account_type = 'equity' AND b.net_debit <> 0
    UNION ALL
    SELECT '30', 'Equity', 'Net Profit/Loss', 'Current Period Performance', v_net_profit
  ) q(section_code, section_name, group_name, account_name, balance)
  ORDER BY q.section_code, q.group_name, q.account_name;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_owner_capital_report_v11(p_start_date DATE, p_end_date DATE)
RETURNS TABLE(posting_date DATE, voucher_no TEXT, narration TEXT, debit NUMERIC, credit NUMERIC, running_balance NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_opening NUMERIC := 0;
  v_ids UUID[];
BEGIN
  SELECT array_agg(id) INTO v_ids
  FROM public.accounts
  WHERE (code IN ('3000', '3010') OR slug IN ('capital', 'owner_drawings', 'drawings'))
    AND name NOT ILIKE '%Adjustment%' AND name NOT ILIKE '%NIL%';

  SELECT COALESCE(SUM(credit_amount - debit_amount), 0)
  INTO v_opening
  FROM public.ledger_entries
  WHERE account_id = ANY(v_ids)
    AND posting_date < p_start_date
    AND (is_reversed = false OR is_reversed IS NULL)
    AND narration NOT ILIKE '%NIL Adjustment%';

  RETURN QUERY
  WITH tx AS (
    SELECT le.posting_date, le.voucher_no, le.narration, le.debit_amount, le.credit_amount, le.created_at,
           SUM(le.credit_amount - le.debit_amount) OVER (ORDER BY le.posting_date, le.created_at) AS period_running
    FROM public.ledger_entries le
    WHERE le.account_id = ANY(v_ids)
      AND le.posting_date BETWEEN p_start_date AND p_end_date
      AND (le.is_reversed = false OR le.is_reversed IS NULL)
      AND le.narration NOT ILIKE '%NIL Adjustment%'
  )
  SELECT tx.posting_date, tx.voucher_no, tx.narration, tx.debit_amount, tx.credit_amount, v_opening + tx.period_running
  FROM tx
  ORDER BY tx.posting_date, tx.created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_fixed_assets_report_v11()
RETURNS TABLE(account_name TEXT, original_value NUMERIC, depreciation NUMERIC, net_value NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT a.name::TEXT,
         COALESCE(SUM(le.debit_amount - le.credit_amount), 0)::NUMERIC,
         0::NUMERIC,
         COALESCE(SUM(le.debit_amount - le.credit_amount), 0)::NUMERIC
  FROM public.accounts a
  LEFT JOIN public.ledger_entries le
    ON le.account_id = a.id
   AND (le.is_reversed = false OR le.is_reversed IS NULL)
  WHERE a.account_type = 'asset'
    AND a.sub_category = 'fixed_asset'
  GROUP BY a.id, a.name
  HAVING COALESCE(SUM(le.debit_amount - le.credit_amount), 0) <> 0;
END;
$$;

-- Robust reversal: does not create negative sale/purchase rows. It marks the
-- source as reversed, posts a balanced opposite journal, and adjusts stock.
CREATE OR REPLACE FUNCTION public.reverse_transaction(p_voucher_no TEXT, p_reason TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_vno TEXT := 'REV-' || p_voucher_no;
  v_sale public.sales%ROWTYPE;
  v_purchase public.purchases%ROWTYPE;
BEGIN
  IF EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = v_new_vno) THEN
    RAISE EXCEPTION 'Voucher % is already reversed.', p_voucher_no;
  END IF;

  SELECT * INTO v_sale FROM public.sales WHERE voucher_no = p_voucher_no AND is_reversed = false;
  IF FOUND THEN
    PERFORM public.update_stock_quantity(v_sale.fuel_type_id, v_sale.quantity, 'IN');
    UPDATE public.sales SET is_reversed = true WHERE id = v_sale.id;
  ELSE
    SELECT * INTO v_purchase FROM public.purchases WHERE voucher_no = p_voucher_no AND is_reversed = false;
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

  UPDATE public.ledger_entries SET is_reversed = true WHERE voucher_no = p_voucher_no;

  RETURN json_build_object('success', true, 'reversal_voucher', v_new_vno);
END;
$$;

-- Basic RLS for new tables.
ALTER TABLE public.accounting_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fiscal_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.report_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fixed_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS accounting_periods_all_authenticated ON public.accounting_periods;
DROP POLICY IF EXISTS fiscal_periods_all_authenticated ON public.fiscal_periods;
DROP POLICY IF EXISTS report_logs_all_authenticated ON public.report_logs;
DROP POLICY IF EXISTS fixed_assets_all_authenticated ON public.fixed_assets;
DROP POLICY IF EXISTS inventory_events_all_authenticated ON public.inventory_events;

CREATE POLICY accounting_periods_all_authenticated ON public.accounting_periods FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY fiscal_periods_all_authenticated ON public.fiscal_periods FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY report_logs_all_authenticated ON public.report_logs FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY fixed_assets_all_authenticated ON public.fixed_assets FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY inventory_events_all_authenticated ON public.inventory_events FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;

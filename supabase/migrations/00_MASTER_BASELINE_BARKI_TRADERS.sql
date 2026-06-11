-- =============================================================================
-- MASTER BASELINE: BARKI TRADERS — Fuel Enterprise Management System
-- =============================================================================
-- Client     : Barki Traders (white-label instance)
-- Purpose    : Single bootstrap script for a NEW Supabase PostgreSQL project
-- Style      : Munshi double-entry · AVCO inventory · strict sale/purchase sync
-- Idempotent : Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE / DROP IF EXISTS)
--
-- Run in     : Supabase Dashboard → SQL Editor → New query → paste → Run
-- Prerequisite: Enable Email auth; create first admin user in Auth, then assign role
-- =============================================================================

BEGIN;

SET search_path = public;

-- =============================================================================
-- SECTION 0: EXTENSIONS
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =============================================================================
-- SECTION 1: ENUMS & AUTH SUPPORT TABLES
-- =============================================================================
DO $$ BEGIN
  CREATE TYPE public.app_role AS ENUM ('admin', 'accountant');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  full_name TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);

-- =============================================================================
-- SECTION 2: CORE FINANCIAL SCHEMA
-- =============================================================================

-- 2.1 Fuel catalogue
CREATE TABLE IF NOT EXISTS public.fuel_types (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  unit TEXT NOT NULL DEFAULT 'Liters',
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2.2 Chart of Accounts (COA)
CREATE TABLE IF NOT EXISTS public.accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  account_type TEXT NOT NULL CHECK (account_type IN ('asset', 'liability', 'equity', 'income', 'expense')),
  slug TEXT UNIQUE,
  sub_category TEXT,
  parent_id UUID REFERENCES public.accounts(id),
  is_system BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2.3 Parties (customers / suppliers unified)
CREATE TABLE IF NOT EXISTS public.parties (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('customer', 'supplier', 'both')),
  phone TEXT,
  address TEXT,
  opening_balance NUMERIC(15, 2) NOT NULL DEFAULT 0,
  current_balance NUMERIC(15, 2) NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id)
);

-- 2.4 Physical stock (quantity + weighted average cost)
CREATE TABLE IF NOT EXISTS public.inventory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fuel_type_id UUID NOT NULL REFERENCES public.fuel_types(id) ON DELETE RESTRICT,
  quantity NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  avg_cost NUMERIC(18, 6) NOT NULL DEFAULT 0,
  last_updated TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (fuel_type_id)
);

-- 2.5 General ledger (double-entry lines)
CREATE TABLE IF NOT EXISTS public.ledger_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  voucher_no TEXT NOT NULL,
  voucher_type TEXT NOT NULL,
  posting_date DATE NOT NULL DEFAULT CURRENT_DATE,
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
  party_id UUID REFERENCES public.parties(id) ON DELETE RESTRICT,
  debit_amount NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (debit_amount >= 0),
  credit_amount NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (credit_amount >= 0),
  narration TEXT,
  quantity NUMERIC(15, 2) DEFAULT 0,
  rate NUMERIC(15, 2) DEFAULT 0,
  is_reversed BOOLEAN NOT NULL DEFAULT false,
  reconciliation_status BOOLEAN NOT NULL DEFAULT false,
  reconciled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id)
);

-- 2.6 Operational vouchers
CREATE TABLE IF NOT EXISTS public.sales (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  voucher_no TEXT NOT NULL UNIQUE,
  sale_date DATE NOT NULL DEFAULT CURRENT_DATE,
  party_id UUID REFERENCES public.parties(id),
  fuel_type_id UUID REFERENCES public.fuel_types(id),
  quantity NUMERIC(15, 2) NOT NULL,
  rate_per_unit NUMERIC(15, 2) NOT NULL,
  total_amount NUMERIC(15, 2) NOT NULL,
  is_credit BOOLEAN NOT NULL DEFAULT true,
  notes TEXT,
  is_reversed BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id)
);

CREATE TABLE IF NOT EXISTS public.purchases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  voucher_no TEXT NOT NULL UNIQUE,
  purchase_date DATE NOT NULL DEFAULT CURRENT_DATE,
  party_id UUID REFERENCES public.parties(id),
  fuel_type_id UUID REFERENCES public.fuel_types(id),
  quantity NUMERIC(15, 2) NOT NULL,
  rate_per_unit NUMERIC(15, 2) NOT NULL,
  total_amount NUMERIC(15, 2) NOT NULL,
  notes TEXT,
  is_reversed BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id)
);

CREATE TABLE IF NOT EXISTS public.payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  voucher_no TEXT NOT NULL UNIQUE,
  payment_date DATE NOT NULL DEFAULT CURRENT_DATE,
  payment_type TEXT NOT NULL CHECK (payment_type IN ('receipt', 'payment')),
  party_id UUID REFERENCES public.parties(id),
  amount NUMERIC(15, 2) NOT NULL CHECK (amount > 0),
  method TEXT NOT NULL DEFAULT 'Cash',
  notes TEXT,
  is_reversed BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id)
);

-- 2.7 Immutable audit trail
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name TEXT NOT NULL,
  record_id UUID,
  voucher_no TEXT,
  action TEXT NOT NULL,
  old_data JSONB,
  new_data JSONB,
  changed_by UUID DEFAULT auth.uid(),
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ip_address TEXT,
  notes TEXT
);

-- =============================================================================
-- SECTION 3: INDEXES (performance)
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_ledger_posting_date ON public.ledger_entries(posting_date);
CREATE INDEX IF NOT EXISTS idx_ledger_voucher_no ON public.ledger_entries(voucher_no);
CREATE INDEX IF NOT EXISTS idx_ledger_account_id ON public.ledger_entries(account_id);
CREATE INDEX IF NOT EXISTS idx_ledger_party_id ON public.ledger_entries(party_id);
CREATE INDEX IF NOT EXISTS idx_ledger_party_date ON public.ledger_entries(party_id, posting_date);
CREATE INDEX IF NOT EXISTS idx_sales_date ON public.sales(sale_date);
CREATE INDEX IF NOT EXISTS idx_sales_party ON public.sales(party_id);
CREATE INDEX IF NOT EXISTS idx_purchases_date ON public.purchases(purchase_date);
CREATE INDEX IF NOT EXISTS idx_purchases_party ON public.purchases(party_id);
CREATE INDEX IF NOT EXISTS idx_payments_date ON public.payments(payment_date);
CREATE INDEX IF NOT EXISTS idx_parties_type ON public.parties(type);

-- =============================================================================
-- SECTION 4: SECURITY HELPERS (RLS policies use these)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid() AND role = 'admin'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.is_accountant()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid() AND role = 'accountant'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role public.app_role)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = _user_id AND role = _role
  );
$$;

CREATE OR REPLACE FUNCTION public.check_v11_permission(p_action TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT;
BEGIN
  SELECT role::TEXT INTO v_role FROM public.user_roles WHERE user_id = auth.uid() LIMIT 1;
  IF p_action = 'DELETE' AND COALESCE(v_role, 'accountant') <> 'admin' THEN
    RAISE EXCEPTION 'PERMISSION DENIED: Only admin can delete. Accountants must use reversals.';
  END IF;
  RETURN TRUE;
END;
$$;

-- =============================================================================
-- SECTION 5: INVENTORY ENGINE (quantity + AVCO)
-- =============================================================================

-- 5.1 Atomic stock movement (IN / OUT) with negative-stock guard
CREATE OR REPLACE FUNCTION public.update_stock_quantity(
  _fuel_type_id UUID,
  _quantity NUMERIC,
  _direction TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_current_qty NUMERIC;
BEGIN
  IF _direction = 'OUT' THEN
    SELECT quantity INTO v_current_qty
    FROM public.inventory
    WHERE fuel_type_id = _fuel_type_id
    FOR UPDATE;

    IF v_current_qty IS NULL OR (v_current_qty - _quantity) < 0 THEN
      RAISE EXCEPTION 'INVENTORY BLOCKED: Insufficient stock. Current: %, Requested OUT: %',
        COALESCE(v_current_qty, 0), _quantity;
    END IF;

    UPDATE public.inventory
    SET quantity = quantity - _quantity,
        last_updated = now()
    WHERE fuel_type_id = _fuel_type_id;

  ELSIF _direction = 'IN' THEN
    UPDATE public.inventory
    SET quantity = quantity + _quantity,
        last_updated = now()
    WHERE fuel_type_id = _fuel_type_id;

    IF NOT FOUND THEN
      INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
      VALUES (_fuel_type_id, _quantity, 0, now())
      ON CONFLICT (fuel_type_id) DO UPDATE
      SET quantity = public.inventory.quantity + EXCLUDED.quantity,
          last_updated = now();
    END IF;
  ELSE
    RAISE EXCEPTION 'Invalid stock direction: %', _direction;
  END IF;
END;
$$;

-- 5.2 Weighted Average Cost (AVCO) — applied on purchase IN
CREATE OR REPLACE FUNCTION public.apply_avco_on_purchase(
  p_fuel_type_id UUID,
  p_quantity NUMERIC,
  p_rate NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_qty NUMERIC := 0;
  v_cost NUMERIC := 0;
  v_new_qty NUMERIC;
  v_new_cost NUMERIC;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'AVCO ERROR: Purchase quantity must be positive.';
  END IF;

  SELECT quantity, avg_cost INTO v_qty, v_cost
  FROM public.inventory
  WHERE fuel_type_id = p_fuel_type_id
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
    VALUES (p_fuel_type_id, p_quantity, p_rate, now())
    ON CONFLICT (fuel_type_id) DO UPDATE
    SET avg_cost = p_rate,
        last_updated = now();
    RETURN;
  END IF;

  v_new_qty := COALESCE(v_qty, 0) + p_quantity;
  IF v_new_qty > 0 THEN
    v_new_cost := ((COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) + (p_quantity * p_rate)) / v_new_qty;
  ELSE
    v_new_cost := p_rate;
  END IF;

  UPDATE public.inventory
  SET avg_cost = v_new_cost,
      last_updated = now()
  WHERE fuel_type_id = p_fuel_type_id;
END;
$$;

-- 5.3 Reverse AVCO when a purchase line is removed (strict stock check)
CREATE OR REPLACE FUNCTION public.reverse_avco_on_purchase(
  p_fuel_type_id UUID,
  p_quantity NUMERIC,
  p_rate NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_qty NUMERIC;
  v_cost NUMERIC;
  v_new_qty NUMERIC;
  v_new_value NUMERIC;
  v_new_cost NUMERIC;
BEGIN
  SELECT quantity, avg_cost INTO v_qty, v_cost
  FROM public.inventory
  WHERE fuel_type_id = p_fuel_type_id
  FOR UPDATE;

  IF NOT FOUND OR COALESCE(v_qty, 0) < p_quantity THEN
    RAISE EXCEPTION 'AVCO REVERSE BLOCKED: Cannot unwind purchase — insufficient stock on hand.';
  END IF;

  v_new_qty := COALESCE(v_qty, 0) - p_quantity;
  v_new_value := (COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) - (p_quantity * p_rate);

  IF v_new_qty > 0 THEN
    v_new_cost := GREATEST(v_new_value, 0) / v_new_qty;
  ELSE
    v_new_cost := 0;
  END IF;

  UPDATE public.inventory
  SET avg_cost = v_new_cost,
      last_updated = now()
  WHERE fuel_type_id = p_fuel_type_id;
END;
$$;

-- =============================================================================
-- SECTION 6: SALE / PURCHASE / PAYMENT TRIGGERS (double-entry + stock)
-- =============================================================================

-- Drop legacy triggers to prevent double-firing
DROP TRIGGER IF EXISTS sync_sale_trigger ON public.sales;
DROP TRIGGER IF EXISTS sync_sale_v11_trigger ON public.sales;
DROP TRIGGER IF EXISTS trg_sale_delete_cascade ON public.sales;
DROP TRIGGER IF EXISTS sync_purchase_trigger ON public.purchases;
DROP TRIGGER IF EXISTS sync_purchase_v11_trigger ON public.purchases;
DROP TRIGGER IF EXISTS trg_purchase_delete_cascade ON public.purchases;
DROP TRIGGER IF EXISTS payment_ledger_trigger ON public.payments;
DROP TRIGGER IF EXISTS trg_payment_delete_cascade ON public.payments;

-- 6.1 PURCHASES → Dr Inventory, Cr AP + stock IN + AVCO
CREATE OR REPLACE FUNCTION public.proc_purchase_ledger_strict()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_ap_id UUID;
  v_inventory_id UUID;
  v_party_name TEXT;
  v_delta NUMERIC;
BEGIN
  SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
  IF v_ap_id IS NULL THEN
    SELECT id INTO v_ap_id FROM public.accounts WHERE code = '2100';
  END IF;

  SELECT id INTO v_inventory_id FROM public.accounts WHERE slug = 'inventory';
  IF v_inventory_id IS NULL THEN
    SELECT id INTO v_inventory_id FROM public.accounts WHERE code = '1200';
  END IF;

  IF v_ap_id IS NULL OR v_inventory_id IS NULL THEN
    RAISE EXCEPTION 'COMPLIANCE ERROR: Accounts Payable or Inventory control account missing.';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT name INTO v_party_name FROM public.parties WHERE id = NEW.party_id;

    PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'IN');
    PERFORM public.apply_avco_on_purchase(NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit);

    INSERT INTO public.ledger_entries (
      voucher_no, voucher_type, posting_date, account_id, party_id,
      debit_amount, credit_amount, narration, quantity, rate, created_by
    ) VALUES
      (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_id, NULL,
       NEW.total_amount, 0, 'Purchase from ' || COALESCE(v_party_name, 'Supplier'),
       NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid())),
      (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id,
       0, NEW.total_amount, 'Credit Purchase - ' || COALESCE(v_party_name, 'Supplier'),
       NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid()));

    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    PERFORM public.reverse_avco_on_purchase(OLD.fuel_type_id, OLD.quantity, OLD.rate_per_unit);
    PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'OUT');
    DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.fuel_type_id IS DISTINCT FROM OLD.fuel_type_id THEN
      PERFORM public.reverse_avco_on_purchase(OLD.fuel_type_id, OLD.quantity, OLD.rate_per_unit);
      PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'OUT');
      PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'IN');
      PERFORM public.apply_avco_on_purchase(NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit);
    ELSIF NEW.quantity IS DISTINCT FROM OLD.quantity OR NEW.rate_per_unit IS DISTINCT FROM OLD.rate_per_unit THEN
      PERFORM public.reverse_avco_on_purchase(OLD.fuel_type_id, OLD.quantity, OLD.rate_per_unit);
      PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'OUT');
      PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'IN');
      PERFORM public.apply_avco_on_purchase(NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit);
    END IF;

    IF NEW.total_amount IS DISTINCT FROM OLD.total_amount
       OR NEW.purchase_date IS DISTINCT FROM OLD.purchase_date
       OR NEW.party_id IS DISTINCT FROM OLD.party_id
       OR NEW.fuel_type_id IS DISTINCT FROM OLD.fuel_type_id
       OR NEW.quantity IS DISTINCT FROM OLD.quantity
       OR NEW.rate_per_unit IS DISTINCT FROM OLD.rate_per_unit THEN

      SELECT name INTO v_party_name FROM public.parties WHERE id = NEW.party_id;
      DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

      INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, party_id,
        debit_amount, credit_amount, narration, quantity, rate, created_by
      ) VALUES
        (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_id, NULL,
         NEW.total_amount, 0, 'Purchase from ' || COALESCE(v_party_name, 'Supplier'),
         NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid())),
        (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id,
         0, NEW.total_amount, 'Credit Purchase - ' || COALESCE(v_party_name, 'Supplier'),
         NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid()));
    END IF;

    RETURN NEW;
  END IF;

  RETURN NULL;
END;
$$;

-- 6.2 SALES → Dr AR, Cr Revenue + COGS + stock OUT (AVCO-based)
CREATE OR REPLACE FUNCTION public.proc_sale_ledger_strict()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_ar_id UUID;
  v_revenue_id UUID;
  v_cogs_id UUID;
  v_inventory_id UUID;
  v_party_name TEXT;
  v_avg_cost NUMERIC := 0;
  v_cogs_amount NUMERIC := 0;
  v_delta NUMERIC;
BEGIN
  SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
  IF v_ar_id IS NULL THEN SELECT id INTO v_ar_id FROM public.accounts WHERE code = '1100'; END IF;

  SELECT id INTO v_revenue_id FROM public.accounts WHERE slug = 'sales_revenue';
  IF v_revenue_id IS NULL THEN SELECT id INTO v_revenue_id FROM public.accounts WHERE code = '4000'; END IF;

  SELECT id INTO v_cogs_id FROM public.accounts WHERE slug = 'cogs';
  IF v_cogs_id IS NULL THEN SELECT id INTO v_cogs_id FROM public.accounts WHERE code = '4100'; END IF;

  SELECT id INTO v_inventory_id FROM public.accounts WHERE slug = 'inventory';
  IF v_inventory_id IS NULL THEN SELECT id INTO v_inventory_id FROM public.accounts WHERE code = '1200'; END IF;

  IF v_ar_id IS NULL OR v_revenue_id IS NULL OR v_cogs_id IS NULL OR v_inventory_id IS NULL THEN
    RAISE EXCEPTION 'COMPLIANCE ERROR: AR, Revenue, COGS, or Inventory account missing.';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT name INTO v_party_name FROM public.parties WHERE id = NEW.party_id;
    SELECT COALESCE(avg_cost, 0) INTO v_avg_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
    v_cogs_amount := NEW.quantity * v_avg_cost;

    PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'OUT');

    INSERT INTO public.ledger_entries (
      voucher_no, voucher_type, posting_date, account_id, party_id,
      debit_amount, credit_amount, narration, quantity, rate, created_by
    ) VALUES
      (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id,
       NEW.total_amount, 0, 'Sale to ' || COALESCE(v_party_name, 'Customer'),
       NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid())),
      (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL,
       0, NEW.total_amount, 'Fuel Sales Revenue',
       NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid())),
      (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL,
       v_cogs_amount, 0, 'Cost of Goods Sold (AVCO)',
       NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid())),
      (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_id, NULL,
       0, v_cogs_amount, 'Inventory credit on sale',
       NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid()));

    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'IN');
    DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.fuel_type_id IS DISTINCT FROM OLD.fuel_type_id THEN
      PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'IN');
      PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'OUT');
    ELSIF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
      v_delta := NEW.quantity - OLD.quantity;
      IF v_delta > 0 THEN
        PERFORM public.update_stock_quantity(NEW.fuel_type_id, v_delta, 'OUT');
      ELSIF v_delta < 0 THEN
        PERFORM public.update_stock_quantity(NEW.fuel_type_id, abs(v_delta), 'IN');
      END IF;
    END IF;

    IF NEW.total_amount IS DISTINCT FROM OLD.total_amount
       OR NEW.sale_date IS DISTINCT FROM OLD.sale_date
       OR NEW.party_id IS DISTINCT FROM OLD.party_id
       OR NEW.fuel_type_id IS DISTINCT FROM OLD.fuel_type_id
       OR NEW.quantity IS DISTINCT FROM OLD.quantity
       OR NEW.rate_per_unit IS DISTINCT FROM OLD.rate_per_unit THEN

      SELECT name INTO v_party_name FROM public.parties WHERE id = NEW.party_id;
      SELECT COALESCE(avg_cost, 0) INTO v_avg_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;
      v_cogs_amount := NEW.quantity * v_avg_cost;

      DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

      INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, party_id,
        debit_amount, credit_amount, narration, quantity, rate, created_by
      ) VALUES
        (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id,
         NEW.total_amount, 0, 'Sale to ' || COALESCE(v_party_name, 'Customer'),
         NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid())),
        (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL,
         0, NEW.total_amount, 'Fuel Sales Revenue',
         NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid())),
        (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL,
         v_cogs_amount, 0, 'Cost of Goods Sold (AVCO)',
         NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid())),
        (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_id, NULL,
         0, v_cogs_amount, 'Inventory credit on sale',
         NEW.quantity, NEW.rate_per_unit, COALESCE(NEW.created_by, auth.uid()));
    END IF;

    RETURN NEW;
  END IF;

  RETURN NULL;
END;
$$;

-- 6.3 PAYMENTS → Receipt: Dr Cash Cr AR | Payment: Dr AP Cr Cash
CREATE OR REPLACE FUNCTION public.proc_payment_ledger_strict()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_cash_id UUID;
  v_ar_id UUID;
  v_ap_id UUID;
BEGIN
  SELECT id INTO v_cash_id FROM public.accounts WHERE slug = 'cash';
  IF v_cash_id IS NULL THEN SELECT id INTO v_cash_id FROM public.accounts WHERE code = '1000'; END IF;

  SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
  IF v_ar_id IS NULL THEN SELECT id INTO v_ar_id FROM public.accounts WHERE code = '1100'; END IF;

  SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
  IF v_ap_id IS NULL THEN SELECT id INTO v_ap_id FROM public.accounts WHERE code = '2100'; END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.payment_type = 'receipt' THEN
      INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, party_id,
        debit_amount, credit_amount, narration, created_by
      ) VALUES
        (NEW.voucher_no, 'receipt', NEW.payment_date, v_cash_id, NULL,
         NEW.amount, 0, COALESCE(NEW.notes, 'Cash Received'), COALESCE(NEW.created_by, auth.uid())),
        (NEW.voucher_no, 'receipt', NEW.payment_date, v_ar_id, NEW.party_id,
         0, NEW.amount, COALESCE(NEW.notes, 'Wasooli'), COALESCE(NEW.created_by, auth.uid()));
    ELSE
      INSERT INTO public.ledger_entries (
        voucher_no, voucher_type, posting_date, account_id, party_id,
        debit_amount, credit_amount, narration, created_by
      ) VALUES
        (NEW.voucher_no, 'payment', NEW.payment_date, v_ap_id, NEW.party_id,
         NEW.amount, 0, COALESCE(NEW.notes, 'Supplier Payment'), COALESCE(NEW.created_by, auth.uid())),
        (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL,
         0, NEW.amount, COALESCE(NEW.notes, 'Cash Paid'), COALESCE(NEW.created_by, auth.uid()));
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

-- 6.4 Party running balance sync (ledger-driven)
CREATE OR REPLACE FUNCTION public.sync_party_balance_v11()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  UPDATE public.parties p
  SET current_balance = COALESCE(p.opening_balance, 0) + COALESCE((
    SELECT SUM(le.debit_amount - le.credit_amount)
    FROM public.ledger_entries le
    WHERE le.party_id = p.id
      AND (le.is_reversed = false OR le.is_reversed IS NULL)
  ), 0)
  WHERE p.id = COALESCE(NEW.party_id, OLD.party_id)
     OR p.id IN (SELECT party_id FROM public.ledger_entries WHERE voucher_no = COALESCE(NEW.voucher_no, OLD.voucher_no));
  RETURN NULL;
END;
$$;

-- 6.5 Cash/Bank negative balance guard
CREATE OR REPLACE FUNCTION public.check_account_balance_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_balance NUMERIC;
  v_slug TEXT;
BEGIN
  SELECT slug INTO v_slug FROM public.accounts WHERE id = NEW.account_id;
  IF v_slug IN ('cash', 'bank') THEN
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0) INTO v_balance
    FROM public.ledger_entries
    WHERE account_id = NEW.account_id
      AND (is_reversed = false OR is_reversed IS NULL);
    v_balance := v_balance + (NEW.debit_amount - NEW.credit_amount);
    IF v_balance < -0.01 THEN
      RAISE EXCEPTION 'FINANCIAL BLOCK: Cash/Bank cannot go negative (balance %).', v_balance;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Attach triggers
DROP TRIGGER IF EXISTS trg_purchase_ledger_strict ON public.purchases;
CREATE TRIGGER trg_purchase_ledger_strict
  AFTER INSERT OR UPDATE OR DELETE ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION public.proc_purchase_ledger_strict();

DROP TRIGGER IF EXISTS trg_sale_ledger_strict ON public.sales;
CREATE TRIGGER trg_sale_ledger_strict
  AFTER INSERT OR UPDATE OR DELETE ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.proc_sale_ledger_strict();

DROP TRIGGER IF EXISTS trg_payment_ledger_strict ON public.payments;
CREATE TRIGGER trg_payment_ledger_strict
  AFTER INSERT OR DELETE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.proc_payment_ledger_strict();

DROP TRIGGER IF EXISTS sync_party_balance_trigger ON public.ledger_entries;
CREATE TRIGGER sync_party_balance_trigger
  AFTER INSERT OR UPDATE OR DELETE ON public.ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public.sync_party_balance_v11();

DROP TRIGGER IF EXISTS trg_check_account_balance ON public.ledger_entries;
CREATE TRIGGER trg_check_account_balance
  AFTER INSERT ON public.ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public.check_account_balance_integrity();

-- =============================================================================
-- SECTION 7: REPORTING & ADMIN RPCs (app-facing)
-- =============================================================================
CREATE SEQUENCE IF NOT EXISTS global_voucher_seq START 10000;

CREATE OR REPLACE FUNCTION public.get_next_voucher_no(p_prefix TEXT, p_date DATE DEFAULT CURRENT_DATE)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_seq BIGINT;
BEGIN
  v_seq := nextval('global_voucher_seq');
  RETURN p_prefix || '-' || to_char(p_date, 'YYYYMMDD') || '-' || lpad(v_seq::TEXT, 6, '0');
END;
$$;

CREATE OR REPLACE FUNCTION public.get_dashboard_v11_3_analytics(p_date DATE)
RETURNS TABLE (
  sales_monthly NUMERIC,
  purchases_monthly NUMERIC,
  receivables NUMERIC,
  payables NUMERIC,
  market_balance NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_month_start DATE := date_trunc('month', p_date)::DATE;
BEGIN
  RETURN QUERY
  WITH party_balances AS (
    SELECT
      p.id,
      (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) AS balance
    FROM public.parties p
    LEFT JOIN public.ledger_entries le
      ON le.party_id = p.id
     AND le.posting_date <= p_date
     AND (le.is_reversed = false OR le.is_reversed IS NULL)
    GROUP BY p.id, p.opening_balance
  )
  SELECT
    (SELECT COALESCE(SUM(total_amount), 0) FROM public.sales
      WHERE sale_date >= v_month_start AND sale_date <= p_date AND is_reversed = false),
    (SELECT COALESCE(SUM(total_amount), 0) FROM public.purchases
      WHERE purchase_date >= v_month_start AND purchase_date <= p_date AND is_reversed = false),
    (SELECT COALESCE(SUM(balance), 0) FROM party_balances WHERE balance > 0),
    (SELECT ABS(COALESCE(SUM(balance), 0)) FROM party_balances WHERE balance < 0),
    (SELECT COALESCE(SUM(balance), 0) FROM party_balances);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_stock_movement(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
  fuel_type_id UUID,
  fuel_name TEXT,
  opening_stock NUMERIC,
  purchased NUMERIC,
  sold NUMERIC,
  closing_stock NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    ft.id,
    ft.name,
    COALESCE(i.quantity, 0)
      - COALESCE((SELECT SUM(s.quantity) FROM public.sales s
          WHERE s.fuel_type_id = ft.id AND s.sale_date >= p_start_date AND s.is_reversed = false), 0)
      + COALESCE((SELECT SUM(pu.quantity) FROM public.purchases pu
          WHERE pu.fuel_type_id = ft.id AND pu.purchase_date >= p_start_date AND pu.is_reversed = false), 0),
    COALESCE((SELECT SUM(pu.quantity) FROM public.purchases pu
      WHERE pu.fuel_type_id = ft.id AND pu.purchase_date BETWEEN p_start_date AND p_end_date AND pu.is_reversed = false), 0),
    COALESCE((SELECT SUM(s.quantity) FROM public.sales s
      WHERE s.fuel_type_id = ft.id AND s.sale_date BETWEEN p_start_date AND p_end_date AND s.is_reversed = false), 0),
    COALESCE(i.quantity, 0)
  FROM public.fuel_types ft
  LEFT JOIN public.inventory i ON i.fuel_type_id = ft.id
  WHERE ft.is_active = true;
END;
$$;

CREATE OR REPLACE FUNCTION public.reverse_transaction(p_voucher_no TEXT, p_reason TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_vno TEXT;
  v_found BOOLEAN := false;
BEGIN
  v_new_vno := 'REV-' || p_voucher_no;

  IF EXISTS (SELECT 1 FROM public.sales WHERE voucher_no = p_voucher_no AND is_reversed = false) THEN
    INSERT INTO public.sales (voucher_no, sale_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, notes, created_by)
    SELECT v_new_vno, CURRENT_DATE, party_id, fuel_type_id, -quantity, rate_per_unit, -total_amount,
           'REV: ' || p_reason, auth.uid()
    FROM public.sales WHERE voucher_no = p_voucher_no LIMIT 1;
    UPDATE public.sales SET is_reversed = true WHERE voucher_no = p_voucher_no;
    v_found := true;
  END IF;

  IF NOT v_found AND EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = p_voucher_no AND is_reversed = false) THEN
    INSERT INTO public.purchases (voucher_no, purchase_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, notes, created_by)
    SELECT v_new_vno, CURRENT_DATE, party_id, fuel_type_id, -quantity, rate_per_unit, -total_amount,
           'REV: ' || p_reason, auth.uid()
    FROM public.purchases WHERE voucher_no = p_voucher_no LIMIT 1;
    UPDATE public.purchases SET is_reversed = true WHERE voucher_no = p_voucher_no;
    v_found := true;
  END IF;

  IF NOT v_found THEN
    RAISE EXCEPTION 'Voucher % not found or already reversed.', p_voucher_no;
  END IF;

  UPDATE public.ledger_entries SET is_reversed = true WHERE voucher_no = p_voucher_no;
  RETURN json_build_object('success', true, 'reversal_voucher', v_new_vno);
END;
$$;

-- =============================================================================
-- SECTION 8: ROW LEVEL SECURITY (admin + accountant / authenticated)
-- =============================================================================
-- Pattern: SELECT/INSERT/UPDATE for all authenticated users (admin + munshi)
--          DELETE restricted to admin only

-- Macro: enable RLS + standard policies per table
-- accounts
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS accounts_select_authenticated ON public.accounts;
DROP POLICY IF EXISTS accounts_insert_authenticated ON public.accounts;
DROP POLICY IF EXISTS accounts_update_authenticated ON public.accounts;
DROP POLICY IF EXISTS accounts_delete_admin_only ON public.accounts;
CREATE POLICY accounts_select_authenticated ON public.accounts FOR SELECT TO authenticated USING (true);
CREATE POLICY accounts_insert_authenticated ON public.accounts FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY accounts_update_authenticated ON public.accounts FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY accounts_delete_admin_only ON public.accounts FOR DELETE TO authenticated USING (public.is_admin());

-- fuel_types
ALTER TABLE public.fuel_types ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fuel_types_select_authenticated ON public.fuel_types;
DROP POLICY IF EXISTS fuel_types_insert_authenticated ON public.fuel_types;
DROP POLICY IF EXISTS fuel_types_update_authenticated ON public.fuel_types;
DROP POLICY IF EXISTS fuel_types_delete_admin_only ON public.fuel_types;
CREATE POLICY fuel_types_select_authenticated ON public.fuel_types FOR SELECT TO authenticated USING (true);
CREATE POLICY fuel_types_insert_authenticated ON public.fuel_types FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY fuel_types_update_authenticated ON public.fuel_types FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY fuel_types_delete_admin_only ON public.fuel_types FOR DELETE TO authenticated USING (public.is_admin());

-- parties
ALTER TABLE public.parties ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS parties_select_authenticated ON public.parties;
DROP POLICY IF EXISTS parties_insert_authenticated ON public.parties;
DROP POLICY IF EXISTS parties_update_authenticated ON public.parties;
DROP POLICY IF EXISTS parties_delete_admin_only ON public.parties;
CREATE POLICY parties_select_authenticated ON public.parties FOR SELECT TO authenticated USING (true);
CREATE POLICY parties_insert_authenticated ON public.parties FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY parties_update_authenticated ON public.parties FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY parties_delete_admin_only ON public.parties FOR DELETE TO authenticated USING (public.is_admin());

-- inventory
ALTER TABLE public.inventory ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS inventory_select_authenticated ON public.inventory;
DROP POLICY IF EXISTS inventory_insert_authenticated ON public.inventory;
DROP POLICY IF EXISTS inventory_update_authenticated ON public.inventory;
DROP POLICY IF EXISTS inventory_delete_admin_only ON public.inventory;
CREATE POLICY inventory_select_authenticated ON public.inventory FOR SELECT TO authenticated USING (true);
CREATE POLICY inventory_insert_authenticated ON public.inventory FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY inventory_update_authenticated ON public.inventory FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY inventory_delete_admin_only ON public.inventory FOR DELETE TO authenticated USING (public.is_admin());

-- ledger_entries
ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ledger_select_authenticated ON public.ledger_entries;
DROP POLICY IF EXISTS ledger_insert_authenticated ON public.ledger_entries;
DROP POLICY IF EXISTS ledger_update_authenticated ON public.ledger_entries;
DROP POLICY IF EXISTS ledger_delete_admin_only ON public.ledger_entries;
CREATE POLICY ledger_select_authenticated ON public.ledger_entries FOR SELECT TO authenticated USING (true);
CREATE POLICY ledger_insert_authenticated ON public.ledger_entries FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY ledger_update_authenticated ON public.ledger_entries FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY ledger_delete_admin_only ON public.ledger_entries FOR DELETE TO authenticated USING (public.is_admin());

-- sales / purchases / payments
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sales_select_authenticated ON public.sales;
DROP POLICY IF EXISTS sales_insert_authenticated ON public.sales;
DROP POLICY IF EXISTS sales_update_authenticated ON public.sales;
DROP POLICY IF EXISTS sales_delete_admin_only ON public.sales;
CREATE POLICY sales_select_authenticated ON public.sales FOR SELECT TO authenticated USING (true);
CREATE POLICY sales_insert_authenticated ON public.sales FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY sales_update_authenticated ON public.sales FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY sales_delete_admin_only ON public.sales FOR DELETE TO authenticated USING (public.is_admin());

ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS purchases_select_authenticated ON public.purchases;
DROP POLICY IF EXISTS purchases_insert_authenticated ON public.purchases;
DROP POLICY IF EXISTS purchases_update_authenticated ON public.purchases;
DROP POLICY IF EXISTS purchases_delete_admin_only ON public.purchases;
CREATE POLICY purchases_select_authenticated ON public.purchases FOR SELECT TO authenticated USING (true);
CREATE POLICY purchases_insert_authenticated ON public.purchases FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY purchases_update_authenticated ON public.purchases FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY purchases_delete_admin_only ON public.purchases FOR DELETE TO authenticated USING (public.is_admin());

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS payments_select_authenticated ON public.payments;
DROP POLICY IF EXISTS payments_insert_authenticated ON public.payments;
DROP POLICY IF EXISTS payments_update_authenticated ON public.payments;
DROP POLICY IF EXISTS payments_delete_admin_only ON public.payments;
CREATE POLICY payments_select_authenticated ON public.payments FOR SELECT TO authenticated USING (true);
CREATE POLICY payments_insert_authenticated ON public.payments FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY payments_update_authenticated ON public.payments FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY payments_delete_admin_only ON public.payments FOR DELETE TO authenticated USING (public.is_admin());

-- user_roles (admin manages; users read own role)
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_roles_select_own ON public.user_roles;
DROP POLICY IF EXISTS user_roles_insert_admin ON public.user_roles;
DROP POLICY IF EXISTS user_roles_update_admin ON public.user_roles;
DROP POLICY IF EXISTS user_roles_delete_admin ON public.user_roles;
CREATE POLICY user_roles_select_own ON public.user_roles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin());
CREATE POLICY user_roles_insert_admin ON public.user_roles FOR INSERT TO authenticated
  WITH CHECK (public.is_admin());
CREATE POLICY user_roles_update_admin ON public.user_roles FOR UPDATE TO authenticated
  USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY user_roles_delete_admin ON public.user_roles FOR DELETE TO authenticated
  USING (public.is_admin());

-- profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS profiles_select_authenticated ON public.profiles;
DROP POLICY IF EXISTS profiles_update_own ON public.profiles;
CREATE POLICY profiles_select_authenticated ON public.profiles FOR SELECT TO authenticated USING (true);
CREATE POLICY profiles_update_own ON public.profiles FOR UPDATE TO authenticated
  USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- audit_logs (read all authenticated; insert allowed; no update/delete)
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS audit_logs_select_authenticated ON public.audit_logs;
DROP POLICY IF EXISTS audit_logs_insert_authenticated ON public.audit_logs;
CREATE POLICY audit_logs_select_authenticated ON public.audit_logs FOR SELECT TO authenticated USING (true);
CREATE POLICY audit_logs_insert_authenticated ON public.audit_logs FOR INSERT TO authenticated WITH CHECK (true);

-- =============================================================================
-- SECTION 9: AUTH — auto-create profile on signup
-- =============================================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data ->> 'full_name')
  ON CONFLICT (id) DO UPDATE
  SET email = EXCLUDED.email,
      full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- =============================================================================
-- SECTION 10: SEED DATA — Bulk Fuel Trader COA + fuel types
-- =============================================================================
INSERT INTO public.fuel_types (name, unit)
VALUES
  ('Petrol', 'Liters'),
  ('Diesel', 'Liters'),
  ('Kerosene', 'Liters')
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.accounts (code, name, account_type, slug, is_system)
VALUES
  ('1000', 'Cash on Hand', 'asset', 'cash', true),
  ('1010', 'Bank Account', 'asset', 'bank', true),
  ('1100', 'Accounts Receivable (Control)', 'asset', 'ar', true),
  ('1200', 'Inventory (Control)', 'asset', 'inventory', true),
  ('2100', 'Accounts Payable (Control)', 'liability', 'ap', true),
  ('3000', 'Owner''s Capital', 'equity', 'capital', true),
  ('4000', 'Sales Revenue', 'income', 'sales_revenue', true),
  ('4100', 'Cost of Goods Sold', 'expense', 'cogs', true),
  ('6000', 'Operating Expenses', 'expense', 'operating_expenses', true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost)
SELECT ft.id, 0, 0
FROM public.fuel_types ft
ON CONFLICT (fuel_type_id) DO NOTHING;

-- =============================================================================
-- SECTION 11: GRANTS (Supabase API roles)
-- =============================================================================
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- =============================================================================
-- POST-RUN: Assign first admin (replace UUID after creating user in Auth)
-- =============================================================================
-- INSERT INTO public.user_roles (user_id, role)
-- VALUES ('YOUR-AUTH-USER-UUID-HERE', 'admin');
--
-- Optional accountant (munshi):
-- INSERT INTO public.user_roles (user_id, role)
-- VALUES ('MUNSHI-USER-UUID', 'accountant');

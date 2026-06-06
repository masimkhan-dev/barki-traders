-- =============================================================================
-- MASTER BASELINE FINAL: New Client Fuel Trust Ledger
-- Run this ONE file on a fresh Supabase project.
-- Generated from the baseline plus frontend-alignment and safety patch sequence.
-- =============================================================================


-- =============================================================================
-- BEGIN SOURCE: supabase\migrations\00_MASTER_BASELINE_BARKI_TRADERS.sql
-- =============================================================================

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
  avg_cost NUMERIC(15, 2) NOT NULL DEFAULT 0,
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

-- =============================================================================
-- END SOURCE: supabase\migrations\00_MASTER_BASELINE_BARKI_TRADERS.sql
-- =============================================================================


-- =============================================================================
-- BEGIN SOURCE: supabase\migrations\01_FRONTEND_ALIGNMENT_NEW_CLIENT.sql
-- =============================================================================

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
  avg_cost_after NUMERIC(15, 2) NOT NULL DEFAULT 0,
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

-- =============================================================================
-- END SOURCE: supabase\migrations\01_FRONTEND_ALIGNMENT_NEW_CLIENT.sql
-- =============================================================================


-- =============================================================================
-- BEGIN SOURCE: supabase\migrations\02_FIX_PARTY_OPENING_BALANCE_DOUBLE_COUNT.sql
-- =============================================================================

-- =============================================================================
-- FIX: Party opening balance double count
-- =============================================================================
-- Run after 01_FRONTEND_ALIGNMENT_NEW_CLIENT.sql.
-- The UI inserts parties with opening_balance and then calls this RPC to post
-- a balanced ledger opening voucher. After posting, the party table opening
-- must be zeroed so statements/trial balance do not count it twice.
-- =============================================================================

BEGIN;
SET search_path = public;

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
    UPDATE public.parties
    SET current_balance = COALESCE(opening_balance, 0)
    WHERE id = p_party_id;
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
    UPDATE public.parties
    SET opening_balance = 0,
        current_balance = COALESCE((
          SELECT SUM(le.debit_amount - le.credit_amount)
          FROM public.ledger_entries le
          WHERE le.party_id = p_party_id
            AND (le.is_reversed = false OR le.is_reversed IS NULL)
        ), 0)
    WHERE id = p_party_id;
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

  UPDATE public.parties
  SET opening_balance = 0,
      current_balance = COALESCE((
        SELECT SUM(le.debit_amount - le.credit_amount)
        FROM public.ledger_entries le
        WHERE le.party_id = p_party_id
          AND (le.is_reversed = false OR le.is_reversed IS NULL)
      ), 0)
  WHERE id = p_party_id;

  RETURN 'SUCCESS: Posted voucher ' || v_voucher;
END;
$$;

-- Repair any parties already affected by the old double-count behavior.
UPDATE public.parties p
SET opening_balance = 0,
    current_balance = COALESCE((
      SELECT SUM(le.debit_amount - le.credit_amount)
      FROM public.ledger_entries le
      WHERE le.party_id = p.id
        AND (le.is_reversed = false OR le.is_reversed IS NULL)
    ), 0)
WHERE p.opening_balance <> 0
  AND EXISTS (
    SELECT 1
    FROM public.ledger_entries le
    WHERE le.party_id = p.id
      AND le.voucher_type = 'opening'
      AND le.voucher_no LIKE 'OB-%'
      AND (le.is_reversed = false OR le.is_reversed IS NULL)
  );

NOTIFY pgrst, 'reload schema';
COMMIT;

-- =============================================================================
-- END SOURCE: supabase\migrations\02_FIX_PARTY_OPENING_BALANCE_DOUBLE_COUNT.sql
-- =============================================================================


-- =============================================================================
-- BEGIN SOURCE: supabase\migrations\03_ENABLE_VOUCHER_FACTORY_PHASE2.sql
-- =============================================================================

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

-- =============================================================================
-- END SOURCE: supabase\migrations\03_ENABLE_VOUCHER_FACTORY_PHASE2.sql
-- =============================================================================


-- =============================================================================
-- BEGIN SOURCE: supabase\migrations\04_FIX_CASH_BANK_NEGATIVE_GUARD.sql
-- =============================================================================

-- =============================================================================
-- FIX: Cash/Bank negative guard double-counts NEW row
-- =============================================================================
-- Run after 03_ENABLE_VOUCHER_FACTORY_PHASE2.sql.
-- The old AFTER INSERT trigger summed ledger_entries, which already includes
-- NEW, then added NEW again. A transfer from bank could be falsely blocked.
-- =============================================================================

BEGIN;
SET search_path = public;

CREATE OR REPLACE FUNCTION public.check_account_balance_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_balance NUMERIC;
  v_slug TEXT;
BEGIN
  SELECT slug INTO v_slug
  FROM public.accounts
  WHERE id = NEW.account_id;

  IF v_slug IN ('cash', 'bank') THEN
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    INTO v_balance
    FROM public.ledger_entries
    WHERE account_id = NEW.account_id
      AND (is_reversed = false OR is_reversed IS NULL);

    IF v_balance < -0.01 THEN
      RAISE EXCEPTION 'FINANCIAL BLOCK: Cash/Bank cannot go negative (balance %).', v_balance;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- =============================================================================
-- END SOURCE: supabase\migrations\04_FIX_CASH_BANK_NEGATIVE_GUARD.sql
-- =============================================================================

-- Fix AVCO double-counting caused by stock quantity being increased before avg_cost calculation.
-- Also repairs existing sale COGS / inventory-credit ledger lines from purchase WAC history.

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
  v_qty_after NUMERIC := 0;
  v_old_qty NUMERIC := 0;
  v_old_cost NUMERIC := 0;
  v_new_cost NUMERIC := 0;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'AVCO ERROR: Purchase quantity must be positive.';
  END IF;

  SELECT COALESCE(quantity, 0), COALESCE(avg_cost, 0)
  INTO v_qty_after, v_old_cost
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

  -- update_stock_quantity(..., 'IN') runs before this function, so remove the current
  -- purchase quantity to recover the true old quantity for weighted average cost.
  v_old_qty := GREATEST(v_qty_after - p_quantity, 0);

  IF v_qty_after > 0 THEN
    v_new_cost := ((v_old_qty * v_old_cost) + (p_quantity * p_rate)) / v_qty_after;
  ELSE
    v_new_cost := p_rate;
  END IF;

  UPDATE public.inventory
  SET avg_cost = v_new_cost,
      last_updated = now()
  WHERE fuel_type_id = p_fuel_type_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.repair_inventory_gl_from_wac()
RETURNS TABLE(fuel_type_id UUID, fuel_name TEXT, sales_repaired INTEGER, final_qty NUMERIC, final_avg_cost NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fuel RECORD;
  v_tx RECORD;
  v_inventory_id UUID;
  v_cogs_id UUID;
  v_qty NUMERIC;
  v_avg NUMERIC;
  v_cogs NUMERIC;
  v_repaired INTEGER;
BEGIN
  SELECT id INTO v_inventory_id FROM public.accounts WHERE slug = 'inventory';
  IF v_inventory_id IS NULL THEN SELECT id INTO v_inventory_id FROM public.accounts WHERE code = '1200'; END IF;

  SELECT id INTO v_cogs_id FROM public.accounts WHERE slug = 'cogs';
  IF v_cogs_id IS NULL THEN SELECT id INTO v_cogs_id FROM public.accounts WHERE code = '4100'; END IF;

  IF v_inventory_id IS NULL OR v_cogs_id IS NULL THEN
    RAISE EXCEPTION 'Missing inventory or COGS account.';
  END IF;

  PERFORM set_config('my.audit_bypass', 'on', true);

  FOR v_fuel IN SELECT id, name FROM public.fuel_types LOOP
    v_qty := 0;
    v_avg := 0;
    v_repaired := 0;

    FOR v_tx IN
      SELECT 'purchase'::TEXT AS tx_type, voucher_no, purchase_date AS tx_date, created_at,
             quantity, rate_per_unit, total_amount
      FROM public.purchases
      WHERE public.purchases.fuel_type_id = v_fuel.id
        AND COALESCE(is_reversed, false) = false

      UNION ALL

      SELECT 'sale'::TEXT AS tx_type, voucher_no, sale_date AS tx_date, created_at,
             quantity, rate_per_unit, total_amount
      FROM public.sales
      WHERE public.sales.fuel_type_id = v_fuel.id
        AND COALESCE(is_reversed, false) = false

      ORDER BY tx_date, created_at, voucher_no
    LOOP
      IF v_tx.tx_type = 'purchase' THEN
        IF (v_qty + v_tx.quantity) > 0 THEN
          v_avg := ((v_qty * v_avg) + v_tx.total_amount) / (v_qty + v_tx.quantity);
        ELSE
          v_avg := v_tx.rate_per_unit;
        END IF;
        v_qty := v_qty + v_tx.quantity;
      ELSE
        v_cogs := ROUND(v_tx.quantity * v_avg, 2);

        UPDATE public.ledger_entries
        SET debit_amount = v_cogs,
            credit_amount = 0
        WHERE voucher_no = v_tx.voucher_no
          AND account_id = v_cogs_id
          AND COALESCE(is_reversed, false) = false;

        UPDATE public.ledger_entries
        SET debit_amount = 0,
            credit_amount = v_cogs
        WHERE voucher_no = v_tx.voucher_no
          AND account_id = v_inventory_id
          AND COALESCE(is_reversed, false) = false;

        v_qty := v_qty - v_tx.quantity;
        v_repaired := v_repaired + 1;
      END IF;
    END LOOP;

    UPDATE public.inventory
    SET quantity = v_qty,
        avg_cost = CASE WHEN v_qty > 0 THEN v_avg ELSE 0 END,
        last_updated = now()
    WHERE public.inventory.fuel_type_id = v_fuel.id;

    fuel_type_id := v_fuel.id;
    fuel_name := v_fuel.name;
    sales_repaired := v_repaired;
    final_qty := v_qty;
    final_avg_cost := CASE WHEN v_qty > 0 THEN v_avg ELSE 0 END;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- Production safety: do not auto-run a historical GL/inventory repair during
-- baseline apply. Run manually after a backup and operator approval:
-- SELECT * FROM public.repair_inventory_gl_from_wac();

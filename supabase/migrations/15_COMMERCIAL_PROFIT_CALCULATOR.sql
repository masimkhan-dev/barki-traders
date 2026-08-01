-- =============================================================================
-- Commercial Profit Calculator (safe, separate from the accounting engine)
--
-- This migration never writes to sales, purchases, inventory, ledger_entries,
-- or the AVCO calculation. Commercial records are append-only snapshots.
-- =============================================================================

ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION public.touch_sales_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_touch_updated_at ON public.sales;
CREATE TRIGGER trg_sales_touch_updated_at
  BEFORE UPDATE ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.touch_sales_updated_at();

CREATE TABLE IF NOT EXISTS public.commercial_profit_calculations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  calculation_date DATE NOT NULL,
  source_sales_fingerprint TEXT NOT NULL,
  source_sale_count INTEGER NOT NULL DEFAULT 0,
  notes TEXT,
  version_no INTEGER NOT NULL DEFAULT 1 CHECK (version_no > 0),
  status TEXT NOT NULL DEFAULT 'reviewed_snapshot'
    CHECK (status IN ('reviewed_snapshot', 'superseded', 'voided')),
  supersedes_id UUID REFERENCES public.commercial_profit_calculations(id) ON DELETE RESTRICT,
  void_reason TEXT,
  created_by UUID NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((status <> 'voided') OR NULLIF(btrim(COALESCE(void_reason, '')), '') IS NOT NULL),
  UNIQUE (calculation_date, version_no)
);

CREATE TABLE IF NOT EXISTS public.commercial_profit_calculation_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  calculation_id UUID NOT NULL REFERENCES public.commercial_profit_calculations(id) ON DELETE RESTRICT,
  fuel_type_id UUID NOT NULL REFERENCES public.fuel_types(id) ON DELETE RESTRICT,
  fuel_name_snapshot TEXT NOT NULL,
  quantity NUMERIC(18, 3) NOT NULL CHECK (quantity >= 0),
  actual_revenue NUMERIC(18, 2) NOT NULL CHECK (actual_revenue >= 0),
  effective_sale_rate NUMERIC(18, 6) NOT NULL CHECK (effective_sale_rate >= 0),
  manual_cost_rate NUMERIC(18, 6) NOT NULL CHECK (manual_cost_rate >= 0),
  estimated_cost NUMERIC(18, 2) NOT NULL CHECK (estimated_cost >= 0),
  commercial_profit NUMERIC(18, 2) NOT NULL,
  margin_percent NUMERIC(12, 6) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (calculation_id, fuel_type_id)
);

CREATE INDEX IF NOT EXISTS idx_commercial_profit_calculations_date
  ON public.commercial_profit_calculations(calculation_date DESC, version_no DESC);
CREATE INDEX IF NOT EXISTS idx_commercial_profit_lines_calculation
  ON public.commercial_profit_calculation_lines(calculation_id);

ALTER TABLE public.commercial_profit_calculations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commercial_profit_calculation_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS commercial_profit_calculations_read_finance ON public.commercial_profit_calculations;
CREATE POLICY commercial_profit_calculations_read_finance
  ON public.commercial_profit_calculations FOR SELECT TO authenticated
  USING (public.is_admin() OR public.is_accountant());

DROP POLICY IF EXISTS commercial_profit_lines_read_finance ON public.commercial_profit_calculation_lines;
CREATE POLICY commercial_profit_lines_read_finance
  ON public.commercial_profit_calculation_lines FOR SELECT TO authenticated
  USING (public.is_admin() OR public.is_accountant());

-- No INSERT/UPDATE/DELETE policies: all writes go through guarded RPCs below.

CREATE OR REPLACE FUNCTION public.get_commercial_profit_source(p_date DATE)
RETURNS TABLE(
  fuel_type_id UUID,
  fuel_name TEXT,
  quantity NUMERIC,
  actual_revenue NUMERIC,
  effective_sale_rate NUMERIC,
  source_sales_fingerprint TEXT,
  source_sale_count INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  WITH active_sales AS (
    SELECT s.id, s.fuel_type_id, s.quantity, s.total_amount, s.is_reversed,
           s.created_at, s.updated_at
    FROM public.sales s
    WHERE s.sale_date = p_date
      AND COALESCE(s.is_reversed, false) = false
      AND s.voucher_no NOT LIKE 'REV-%'
  ), fingerprint AS (
    SELECT
      encode(digest(COALESCE(string_agg(
        concat_ws('|', id::TEXT, updated_at::TEXT, fuel_type_id::TEXT,
          quantity::TEXT, total_amount::TEXT, is_reversed::TEXT),
        E'\n' ORDER BY id
      ), '')::bytea, 'sha256'), 'hex') AS value,
      COUNT(*)::INTEGER AS sale_count
    FROM active_sales
  )
  SELECT
    a.fuel_type_id,
    ft.name::TEXT,
    ROUND(SUM(a.quantity), 3)::NUMERIC,
    ROUND(SUM(a.total_amount), 2)::NUMERIC,
    ROUND(SUM(a.total_amount) / NULLIF(SUM(a.quantity), 0), 6)::NUMERIC,
    f.value,
    f.sale_count
  FROM active_sales a
  JOIN public.fuel_types ft ON ft.id = a.fuel_type_id
  CROSS JOIN fingerprint f
  GROUP BY a.fuel_type_id, ft.name, f.value, f.sale_count
  ORDER BY ft.name;
$$;

CREATE OR REPLACE FUNCTION public.save_commercial_profit_calculation(
  p_date DATE,
  p_manual_lines JSONB,
  p_notes TEXT DEFAULT NULL,
  p_supersedes_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_id UUID;
  v_fingerprint TEXT;
  v_sale_count INTEGER;
  v_next_version INTEGER;
  v_source_count INTEGER;
BEGIN
  IF NOT (public.is_admin() OR public.is_accountant()) THEN
    RAISE EXCEPTION 'PERMISSION DENIED: Admin or Accountant access is required.';
  END IF;

  IF p_date IS NULL OR p_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'A valid calculation date up to today is required.';
  END IF;

  IF jsonb_typeof(p_manual_lines) <> 'array' OR jsonb_array_length(p_manual_lines) = 0 THEN
    RAISE EXCEPTION 'At least one manual cost-rate line is required.';
  END IF;

  SELECT COALESCE(MAX(version_no), 0) + 1
  INTO v_next_version
  FROM public.commercial_profit_calculations
  WHERE calculation_date = p_date;

  SELECT COALESCE(MAX(source_sales_fingerprint), encode(digest(''::bytea, 'sha256'), 'hex')),
         COALESCE(MAX(source_sale_count), 0)
  INTO v_fingerprint, v_sale_count
  FROM public.get_commercial_profit_source(p_date);

  SELECT COUNT(*) INTO v_source_count
  FROM public.get_commercial_profit_source(p_date);
  IF v_source_count = 0 THEN
    RAISE EXCEPTION 'No active sales were found for the selected date.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_manual_lines) AS x(fuel_type_id UUID, manual_cost_rate NUMERIC)
    WHERE fuel_type_id IS NULL OR manual_cost_rate IS NULL OR manual_cost_rate < 0
  ) THEN
    RAISE EXCEPTION 'Every source fuel requires a non-negative manual cost rate.';
  END IF;

  IF (SELECT COUNT(DISTINCT fuel_type_id)
      FROM jsonb_to_recordset(p_manual_lines) AS x(fuel_type_id UUID, manual_cost_rate NUMERIC))
     <> v_source_count
     OR EXISTS (
       SELECT 1 FROM public.get_commercial_profit_source(p_date) s
       LEFT JOIN jsonb_to_recordset(p_manual_lines) AS x(fuel_type_id UUID, manual_cost_rate NUMERIC)
         ON x.fuel_type_id = s.fuel_type_id
       WHERE x.fuel_type_id IS NULL
     )
     OR EXISTS (
       SELECT 1 FROM jsonb_to_recordset(p_manual_lines) AS x(fuel_type_id UUID, manual_cost_rate NUMERIC)
       LEFT JOIN public.get_commercial_profit_source(p_date) s
         ON s.fuel_type_id = x.fuel_type_id
       WHERE s.fuel_type_id IS NULL
     ) THEN
    RAISE EXCEPTION 'Manual lines must match every fuel loaded from the source sales.';
  END IF;

  IF p_supersedes_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.commercial_profit_calculations
    WHERE id = p_supersedes_id AND calculation_date = p_date
  ) THEN
    RAISE EXCEPTION 'The calculation being revised was not found for this date.';
  END IF;

  INSERT INTO public.commercial_profit_calculations (
    calculation_date, source_sales_fingerprint, source_sale_count, notes,
    version_no, status, supersedes_id, created_by
  ) VALUES (
    p_date, v_fingerprint, v_sale_count, NULLIF(btrim(COALESCE(p_notes, '')), ''),
    v_next_version, 'reviewed_snapshot', p_supersedes_id, auth.uid()
  ) RETURNING id INTO v_id;

  INSERT INTO public.commercial_profit_calculation_lines (
    calculation_id, fuel_type_id, fuel_name_snapshot, quantity, actual_revenue,
    effective_sale_rate, manual_cost_rate, estimated_cost, commercial_profit, margin_percent
  )
  SELECT
    v_id, s.fuel_type_id, s.fuel_name, s.quantity, s.actual_revenue,
    s.effective_sale_rate, l.manual_cost_rate,
    ROUND(s.quantity * l.manual_cost_rate, 2),
    ROUND(s.actual_revenue - (s.quantity * l.manual_cost_rate), 2),
    ROUND(((s.actual_revenue - (s.quantity * l.manual_cost_rate)) /
      NULLIF(s.actual_revenue, 0)) * 100, 6)
  FROM public.get_commercial_profit_source(p_date) s
  JOIN jsonb_to_recordset(p_manual_lines) AS l(fuel_type_id UUID, manual_cost_rate NUMERIC)
    ON l.fuel_type_id = s.fuel_type_id;

  IF p_supersedes_id IS NOT NULL THEN
    UPDATE public.commercial_profit_calculations
    SET status = 'superseded'
    WHERE id = p_supersedes_id AND status = 'reviewed_snapshot';
  END IF;

  INSERT INTO public.audit_logs (table_name, record_id, action, new_data, notes)
  VALUES ('commercial_profit_calculations', v_id, 'INSERT',
    jsonb_build_object('calculation_date', p_date, 'version_no', v_next_version),
    'Commercial estimate snapshot saved; no accounting records were changed.');

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_commercial_profit_calculation(
  p_calculation_id UUID,
  p_reason TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'PERMISSION DENIED: Only an Admin can void a commercial calculation.';
  END IF;
  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'A void reason is required.';
  END IF;
  UPDATE public.commercial_profit_calculations
  SET status = 'voided', void_reason = btrim(p_reason)
  WHERE id = p_calculation_id AND status <> 'voided';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Calculation was not found or is already voided.';
  END IF;
END;
$$;

GRANT SELECT ON public.commercial_profit_calculations TO authenticated, service_role;
GRANT SELECT ON public.commercial_profit_calculation_lines TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_commercial_profit_source(DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_commercial_profit_calculation(DATE, JSONB, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_commercial_profit_calculation(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- Migration: 13_TRADING_MARGIN_WATERFALL.sql (REFINED SAFETY VERSION)
-- Description: Safe Trading Margin Waterfall view & RPCs with security_invoker
-- ============================================================================

-- 1. Create read-only view public.v_sale_profit_waterfall with security_invoker = true
CREATE OR REPLACE VIEW public.v_sale_profit_waterfall
WITH (security_invoker = true)
AS
WITH active_sales AS (
  SELECT
    s.id AS sale_id,
    s.voucher_no,
    s.sale_date,
    s.created_at AS sale_created_at,
    s.party_id,
    s.fuel_type_id,
    s.quantity,
    s.rate_per_unit AS selling_rate,
    s.total_amount AS revenue
  FROM public.sales s
  WHERE COALESCE(s.is_reversed, false) = false
),

sale_cogs AS (
  SELECT
    le.voucher_no,
    ROUND(
      SUM(
        COALESCE(le.debit_amount, 0)
        - COALESCE(le.credit_amount, 0)
      ),
      2
    ) AS avco_cogs,
    COUNT(*) FILTER (
      WHERE COALESCE(le.debit_amount, 0) > 0
    ) AS cogs_debit_line_count
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'cogs' OR (a.code = '4100' AND a.account_type = 'expense'))
    AND COALESCE(le.is_reversed, false) = false
  GROUP BY le.voucher_no
)

SELECT
  s.sale_id,
  s.voucher_no,
  s.sale_date,
  s.sale_created_at,
  s.party_id,
  s.fuel_type_id,
  ft.name AS fuel_type,

  s.quantity,
  s.selling_rate,
  s.revenue,

  lp.purchase_id AS reference_purchase_id,
  lp.voucher_no AS reference_purchase_voucher,
  lp.purchase_date AS reference_purchase_date,
  lp.purchase_created_at,
  lp.latest_purchase_rate AS replacement_rate,

  CASE
    WHEN lp.latest_purchase_rate IS NULL THEN NULL
    ELSE ROUND(
      s.quantity * lp.latest_purchase_rate,
      2
    )
  END AS replacement_cost,

  CASE
    WHEN lp.latest_purchase_rate IS NULL THEN NULL
    ELSE ROUND(
      s.revenue
      - s.quantity * lp.latest_purchase_rate,
      2
    )
  END AS trading_margin,

  c.avco_cogs,

  CASE
    WHEN c.avco_cogs IS NULL THEN NULL
    ELSE ROUND(
      c.avco_cogs / NULLIF(s.quantity, 0),
      6
    )
  END AS avco_rate,

  CASE
    WHEN lp.latest_purchase_rate IS NULL
      OR c.avco_cogs IS NULL
    THEN NULL
    ELSE ROUND(
      s.quantity * lp.latest_purchase_rate
      - c.avco_cogs,
      2
    )
  END AS inventory_holding_gain_loss,

  CASE
    WHEN c.avco_cogs IS NULL THEN NULL
    ELSE ROUND(
      s.revenue - c.avco_cogs,
      2
    )
  END AS accounting_gross_profit,

  CASE
    WHEN lp.latest_purchase_rate IS NULL
      OR c.avco_cogs IS NULL
    THEN NULL
    ELSE ROUND(
      (
        s.revenue
        - s.quantity * lp.latest_purchase_rate
      )
      +
      (
        s.quantity * lp.latest_purchase_rate
        - c.avco_cogs
      )
      -
      (
        s.revenue - c.avco_cogs
      ),
      2
    )
  END AS reconciliation_difference,

  CASE
    WHEN lp.latest_purchase_rate IS NULL
      THEN 'MISSING_REFERENCE_PURCHASE'
    WHEN c.avco_cogs IS NULL
      THEN 'MISSING_COGS'
    WHEN COALESCE(c.cogs_debit_line_count, 0) = 0
      THEN 'MISSING_COGS_DEBIT'
    WHEN ABS(
      (
        s.revenue
        - s.quantity * lp.latest_purchase_rate
      )
      +
      (
        s.quantity * lp.latest_purchase_rate
        - c.avco_cogs
      )
      -
      (
        s.revenue - c.avco_cogs
      )
    ) > 0.02
      THEN 'RECONCILIATION_ERROR'
    ELSE 'VERIFIED'
  END AS waterfall_status

FROM active_sales s

JOIN public.fuel_types ft
  ON ft.id = s.fuel_type_id

LEFT JOIN sale_cogs c
  ON c.voucher_no = s.voucher_no

LEFT JOIN LATERAL (
  SELECT
    p.id AS purchase_id,
    p.voucher_no,
    p.purchase_date,
    p.created_at AS purchase_created_at,
    p.rate_per_unit AS latest_purchase_rate
  FROM public.purchases p
  WHERE p.fuel_type_id = s.fuel_type_id
    AND COALESCE(p.is_reversed, false) = false
    AND p.created_at <= s.sale_created_at
  ORDER BY
    p.created_at DESC,
    p.purchase_date DESC,
    p.id DESC
  LIMIT 1
) lp ON true;


-- 2. Period Summary RPC: public.get_trading_margin_summary
CREATE OR REPLACE FUNCTION public.get_trading_margin_summary(
  p_from_date date,
  p_to_date date
)
RETURNS TABLE (
  total_sales_revenue numeric,
  verified_sales_revenue numeric,
  replacement_cost numeric,
  trading_margin numeric,
  inventory_holding_gain_loss numeric,
  avco_cogs numeric,
  accounting_gross_profit numeric,
  reconciliation_difference numeric,
  verified_sales_count bigint,
  warning_sales_count bigint,
  missing_reference_purchase_count bigint,
  missing_cogs_count bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    ROUND(COALESCE(SUM(v.revenue), 0), 2) AS total_sales_revenue,
    ROUND(
      COALESCE(
        SUM(v.revenue) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS verified_sales_revenue,
    ROUND(
      COALESCE(
        SUM(v.replacement_cost) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS replacement_cost,
    ROUND(
      COALESCE(
        SUM(v.trading_margin) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS trading_margin,
    ROUND(
      COALESCE(
        SUM(v.inventory_holding_gain_loss) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS inventory_holding_gain_loss,
    ROUND(
      COALESCE(
        SUM(v.avco_cogs) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS avco_cogs,
    ROUND(
      COALESCE(
        SUM(v.accounting_gross_profit) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS accounting_gross_profit,
    ROUND(
      COALESCE(
        SUM(v.reconciliation_difference) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS reconciliation_difference,
    COUNT(*) FILTER (WHERE v.waterfall_status = 'VERIFIED') AS verified_sales_count,
    COUNT(*) FILTER (WHERE v.waterfall_status <> 'VERIFIED') AS warning_sales_count,
    COUNT(*) FILTER (WHERE v.waterfall_status = 'MISSING_REFERENCE_PURCHASE') AS missing_reference_purchase_count,
    COUNT(*) FILTER (WHERE v.waterfall_status IN ('MISSING_COGS', 'MISSING_COGS_DEBIT')) AS missing_cogs_count
  FROM public.v_sale_profit_waterfall v
  WHERE v.sale_date BETWEEN p_from_date AND p_to_date;
$$;


-- 3. Fuel-wise Breakdown RPC: public.get_trading_margin_by_fuel
CREATE OR REPLACE FUNCTION public.get_trading_margin_by_fuel(
  p_from_date date,
  p_to_date date
)
RETURNS TABLE (
  fuel_type_id uuid,
  fuel_type text,
  sold_quantity numeric,
  average_selling_rate numeric,
  replacement_cost numeric,
  trading_margin numeric,
  inventory_holding_gain_loss numeric,
  avco_cogs numeric,
  accounting_gross_profit numeric,
  reconciliation_difference numeric,
  missing_reference_purchase_count bigint,
  missing_cogs_count bigint,
  fuel_status text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    v.fuel_type_id,
    v.fuel_type,
    ROUND(COALESCE(SUM(v.quantity), 0), 2) AS sold_quantity,
    CASE 
      WHEN SUM(v.quantity) > 0 THEN ROUND(SUM(v.revenue) / SUM(v.quantity), 2)
      ELSE 0
    END AS average_selling_rate,
    ROUND(
      COALESCE(
        SUM(v.replacement_cost) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS replacement_cost,
    ROUND(
      COALESCE(
        SUM(v.trading_margin) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS trading_margin,
    ROUND(
      COALESCE(
        SUM(v.inventory_holding_gain_loss) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS inventory_holding_gain_loss,
    ROUND(
      COALESCE(
        SUM(v.avco_cogs) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS avco_cogs,
    ROUND(
      COALESCE(
        SUM(v.accounting_gross_profit) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS accounting_gross_profit,
    ROUND(
      COALESCE(
        SUM(v.reconciliation_difference) FILTER (WHERE v.waterfall_status = 'VERIFIED'),
        0
      ),
      2
    ) AS reconciliation_difference,
    COUNT(*) FILTER (WHERE v.waterfall_status = 'MISSING_REFERENCE_PURCHASE') AS missing_reference_purchase_count,
    COUNT(*) FILTER (WHERE v.waterfall_status IN ('MISSING_COGS', 'MISSING_COGS_DEBIT')) AS missing_cogs_count,
    CASE
      WHEN COUNT(*) FILTER (WHERE v.waterfall_status <> 'VERIFIED') > 0 THEN 'REQUIRES_REVIEW'
      ELSE 'VERIFIED'
    END AS fuel_status
  FROM public.v_sale_profit_waterfall v
  WHERE v.sale_date BETWEEN p_from_date AND p_to_date
  GROUP BY v.fuel_type_id, v.fuel_type
  ORDER BY v.fuel_type;
$$;


-- 4. RLS & Security: Revoke from anon, Grant to authenticated + service_role
REVOKE ALL ON public.v_sale_profit_waterfall FROM anon;
REVOKE ALL ON FUNCTION public.get_trading_margin_summary(date, date) FROM anon;
REVOKE ALL ON FUNCTION public.get_trading_margin_by_fuel(date, date) FROM anon;

GRANT SELECT ON public.v_sale_profit_waterfall TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_trading_margin_summary(date, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_trading_margin_by_fuel(date, date) TO authenticated, service_role;

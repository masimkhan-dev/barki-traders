-- Read-only dashboard analytics RPCs.
-- Safety scope: new SELECT-only functions. No table changes, no trigger changes,
-- no transaction/reversal/inventory mutation logic changes.

CREATE OR REPLACE FUNCTION public.get_dashboard_sales_purchases_trend(
  p_start_date DATE,
  p_end_date DATE
)
RETURNS TABLE(tx_date DATE, sales_amount NUMERIC, purchases_amount NUMERIC)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH days AS (
    SELECT generate_series(p_start_date, p_end_date, interval '1 day')::DATE AS tx_date
  ),
  sales_daily AS (
    SELECT
      s.sale_date AS tx_date,
      SUM(s.total_amount)::NUMERIC AS sales_amount
    FROM public.sales s
    WHERE s.sale_date BETWEEN p_start_date AND p_end_date
      AND COALESCE(s.is_reversed, false) = false
      AND s.voucher_no NOT LIKE 'REV-%'
    GROUP BY s.sale_date
  ),
  purchases_daily AS (
    SELECT
      p.purchase_date AS tx_date,
      SUM(p.total_amount)::NUMERIC AS purchases_amount
    FROM public.purchases p
    WHERE p.purchase_date BETWEEN p_start_date AND p_end_date
      AND COALESCE(p.is_reversed, false) = false
      AND p.voucher_no NOT LIKE 'REV-%'
    GROUP BY p.purchase_date
  )
  SELECT
    d.tx_date,
    COALESCE(sd.sales_amount, 0)::NUMERIC AS sales_amount,
    COALESCE(pd.purchases_amount, 0)::NUMERIC AS purchases_amount
  FROM days d
  LEFT JOIN sales_daily sd ON sd.tx_date = d.tx_date
  LEFT JOIN purchases_daily pd ON pd.tx_date = d.tx_date
  ORDER BY d.tx_date;
$$;

CREATE OR REPLACE FUNCTION public.get_dashboard_cash_flow_trend(
  p_start_date DATE,
  p_end_date DATE
)
RETURNS TABLE(tx_date DATE, cash_in NUMERIC, cash_out NUMERIC, net_cash_flow NUMERIC)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH days AS (
    SELECT generate_series(p_start_date, p_end_date, interval '1 day')::DATE AS tx_date
  ),
  cash_accounts AS (
    SELECT a.id
    FROM public.accounts a
    WHERE COALESCE(a.slug, '') IN ('cash', 'bank')
       OR a.code IN ('1000', '1010')
       OR lower(a.name) LIKE '%cash%'
       OR lower(a.name) LIKE '%bank%'
  ),
  cash_daily AS (
    SELECT
      le.posting_date AS tx_date,
      SUM(le.debit_amount)::NUMERIC AS cash_in,
      SUM(le.credit_amount)::NUMERIC AS cash_out
    FROM public.ledger_entries le
    JOIN cash_accounts ca ON ca.id = le.account_id
    WHERE le.posting_date BETWEEN p_start_date AND p_end_date
      AND COALESCE(le.is_reversed, false) = false
      AND le.voucher_no NOT LIKE 'REV-%'
    GROUP BY le.posting_date
  )
  SELECT
    d.tx_date,
    COALESCE(cd.cash_in, 0)::NUMERIC AS cash_in,
    COALESCE(cd.cash_out, 0)::NUMERIC AS cash_out,
    (COALESCE(cd.cash_in, 0) - COALESCE(cd.cash_out, 0))::NUMERIC AS net_cash_flow
  FROM days d
  LEFT JOIN cash_daily cd ON cd.tx_date = d.tx_date
  ORDER BY d.tx_date;
$$;

CREATE OR REPLACE FUNCTION public.get_dashboard_stock_by_fuel()
RETURNS TABLE(
  fuel_type_id UUID,
  fuel_name TEXT,
  unit TEXT,
  quantity NUMERIC,
  avg_cost NUMERIC,
  stock_value NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ft.id AS fuel_type_id,
    ft.name::TEXT AS fuel_name,
    ft.unit::TEXT AS unit,
    COALESCE(i.quantity, 0)::NUMERIC AS quantity,
    COALESCE(i.avg_cost, 0)::NUMERIC AS avg_cost,
    ROUND(COALESCE(i.quantity, 0) * COALESCE(i.avg_cost, 0), 2)::NUMERIC AS stock_value
  FROM public.fuel_types ft
  LEFT JOIN public.inventory i ON i.fuel_type_id = ft.id
  WHERE ft.is_active = true
  ORDER BY ft.name;
$$;

CREATE OR REPLACE FUNCTION public.get_dashboard_receivables_payables()
RETURNS TABLE(receivables NUMERIC, payables NUMERIC, net_position NUMERIC)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH party_balances AS (
    SELECT
      p.id,
      p.type,
      (
        COALESCE(p.opening_balance, 0)
        + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
      )::NUMERIC AS balance
    FROM public.parties p
    LEFT JOIN public.ledger_entries le
      ON le.party_id = p.id
     AND COALESCE(le.is_reversed, false) = false
     AND le.voucher_no NOT LIKE 'REV-%'
    WHERE p.is_active = true
    GROUP BY p.id, p.type, p.opening_balance
  )
  SELECT
    COALESCE(SUM(CASE WHEN balance > 0 THEN balance ELSE 0 END), 0)::NUMERIC AS receivables,
    COALESCE(SUM(CASE WHEN balance < 0 THEN ABS(balance) ELSE 0 END), 0)::NUMERIC AS payables,
    COALESCE(SUM(balance), 0)::NUMERIC AS net_position
  FROM party_balances;
$$;

CREATE OR REPLACE FUNCTION public.get_dashboard_top_customers(p_limit INT DEFAULT 5)
RETURNS TABLE(party_id UUID, party_name TEXT, outstanding_amount NUMERIC)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH party_balances AS (
    SELECT
      p.id AS party_id,
      p.name::TEXT AS party_name,
      (
        COALESCE(p.opening_balance, 0)
        + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
      )::NUMERIC AS balance
    FROM public.parties p
    LEFT JOIN public.ledger_entries le
      ON le.party_id = p.id
     AND COALESCE(le.is_reversed, false) = false
     AND le.voucher_no NOT LIKE 'REV-%'
    WHERE p.is_active = true
      AND p.type IN ('customer', 'both')
    GROUP BY p.id, p.name, p.opening_balance
  )
  SELECT
    party_id,
    party_name,
    ROUND(balance, 2)::NUMERIC AS outstanding_amount
  FROM party_balances
  WHERE balance > 0
  ORDER BY balance DESC, party_name
  LIMIT GREATEST(COALESCE(p_limit, 5), 0);
$$;

CREATE OR REPLACE FUNCTION public.get_dashboard_top_suppliers(p_limit INT DEFAULT 5)
RETURNS TABLE(party_id UUID, party_name TEXT, payable_amount NUMERIC)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH party_balances AS (
    SELECT
      p.id AS party_id,
      p.name::TEXT AS party_name,
      (
        COALESCE(p.opening_balance, 0)
        + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
      )::NUMERIC AS balance
    FROM public.parties p
    LEFT JOIN public.ledger_entries le
      ON le.party_id = p.id
     AND COALESCE(le.is_reversed, false) = false
     AND le.voucher_no NOT LIKE 'REV-%'
    WHERE p.is_active = true
      AND p.type IN ('supplier', 'both')
    GROUP BY p.id, p.name, p.opening_balance
  )
  SELECT
    party_id,
    party_name,
    ROUND(ABS(balance), 2)::NUMERIC AS payable_amount
  FROM party_balances
  WHERE balance < 0
  ORDER BY ABS(balance) DESC, party_name
  LIMIT GREATEST(COALESCE(p_limit, 5), 0);
$$;

CREATE OR REPLACE FUNCTION public.get_dashboard_profit_trend(
  p_start_date DATE,
  p_end_date DATE
)
RETURNS TABLE(tx_date DATE, income NUMERIC, expense NUMERIC, gross_profit NUMERIC)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH days AS (
    SELECT generate_series(p_start_date, p_end_date, interval '1 day')::DATE AS tx_date
  ),
  profit_daily AS (
    SELECT
      le.posting_date AS tx_date,
      SUM(
        CASE
          WHEN a.account_type = 'income' THEN le.credit_amount - le.debit_amount
          ELSE 0
        END
      )::NUMERIC AS income,
      SUM(
        CASE
          WHEN a.account_type = 'expense' THEN le.debit_amount - le.credit_amount
          ELSE 0
        END
      )::NUMERIC AS expense
    FROM public.ledger_entries le
    JOIN public.accounts a ON a.id = le.account_id
    WHERE le.posting_date BETWEEN p_start_date AND p_end_date
      AND a.account_type IN ('income', 'expense')
      AND COALESCE(le.is_reversed, false) = false
      AND le.voucher_no NOT LIKE 'REV-%'
    GROUP BY le.posting_date
  )
  SELECT
    d.tx_date,
    COALESCE(pd.income, 0)::NUMERIC AS income,
    COALESCE(pd.expense, 0)::NUMERIC AS expense,
    (COALESCE(pd.income, 0) - COALESCE(pd.expense, 0))::NUMERIC AS gross_profit
  FROM days d
  LEFT JOIN profit_daily pd ON pd.tx_date = d.tx_date
  ORDER BY d.tx_date;
$$;

CREATE OR REPLACE FUNCTION public.get_dashboard_fuel_quantity_sold(
  p_start_date DATE,
  p_end_date DATE
)
RETURNS TABLE(fuel_type_id UUID, fuel_name TEXT, unit TEXT, quantity_sold NUMERIC, sales_amount NUMERIC)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ft.id AS fuel_type_id,
    ft.name::TEXT AS fuel_name,
    ft.unit::TEXT AS unit,
    COALESCE(SUM(s.quantity), 0)::NUMERIC AS quantity_sold,
    COALESCE(SUM(s.total_amount), 0)::NUMERIC AS sales_amount
  FROM public.fuel_types ft
  LEFT JOIN public.sales s
    ON s.fuel_type_id = ft.id
   AND s.sale_date BETWEEN p_start_date AND p_end_date
   AND COALESCE(s.is_reversed, false) = false
   AND s.voucher_no NOT LIKE 'REV-%'
  WHERE ft.is_active = true
  GROUP BY ft.id, ft.name, ft.unit
  HAVING COALESCE(SUM(s.quantity), 0) <> 0
  ORDER BY quantity_sold DESC, ft.name;
$$;

-- Inventory, WAC, and balance-sheet audit queries.
-- Run in Supabase SQL Editor. These are SELECT-only except the final repair
-- command, which is intentionally commented out.

-- 1) Dashboard inventory source: what the app currently reads.
SELECT
  ft.name AS fuel_name,
  i.quantity,
  i.avg_cost,
  ROUND(i.quantity * i.avg_cost, 2) AS dashboard_stock_value
FROM public.inventory i
JOIN public.fuel_types ft ON ft.id = i.fuel_type_id
ORDER BY ft.name;

-- 2) Balance sheet inventory control account value from ledger.
SELECT
  a.code,
  a.name,
  a.slug,
  ROUND(SUM(le.debit_amount - le.credit_amount), 2) AS ledger_inventory_value
FROM public.accounts a
LEFT JOIN public.ledger_entries le
  ON le.account_id = a.id
 AND COALESCE(le.is_reversed, false) = false
 AND le.voucher_no NOT LIKE 'REV-%'
WHERE a.slug = 'inventory' OR a.code = '1200'
GROUP BY a.code, a.name, a.slug;

-- 3) Dashboard inventory value vs ledger inventory value.
WITH dashboard_inventory AS (
  SELECT ROUND(COALESCE(SUM(i.quantity * i.avg_cost), 0), 2) AS value
  FROM public.inventory i
),
ledger_inventory AS (
  SELECT ROUND(COALESCE(SUM(le.debit_amount - le.credit_amount), 0), 2) AS value
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'inventory' OR a.code = '1200')
    AND COALESCE(le.is_reversed, false) = false
    AND le.voucher_no NOT LIKE 'REV-%'
)
SELECT
  d.value AS dashboard_inventory_value,
  l.value AS ledger_inventory_value,
  ROUND(d.value - l.value, 2) AS difference
FROM dashboard_inventory d
CROSS JOIN ledger_inventory l;

-- 4) Physical quantity cache drift: inventory table vs purchase-minus-sale.
WITH movement AS (
  SELECT
    fuel_type_id,
    SUM(qty) AS computed_quantity
  FROM (
    SELECT fuel_type_id, quantity AS qty
    FROM public.purchases
    WHERE COALESCE(is_reversed, false) = false
      AND voucher_no NOT LIKE 'REV-%'

    UNION ALL

    SELECT fuel_type_id, -quantity AS qty
    FROM public.sales
    WHERE COALESCE(is_reversed, false) = false
      AND voucher_no NOT LIKE 'REV-%'
  ) x
  GROUP BY fuel_type_id
)
SELECT
  ft.name AS fuel_name,
  COALESCE(m.computed_quantity, 0) AS computed_quantity,
  COALESCE(i.quantity, 0) AS cached_quantity,
  ROUND(COALESCE(i.quantity, 0) - COALESCE(m.computed_quantity, 0), 2) AS quantity_drift
FROM public.fuel_types ft
LEFT JOIN movement m ON m.fuel_type_id = ft.id
LEFT JOIN public.inventory i ON i.fuel_type_id = ft.id
ORDER BY ABS(COALESCE(i.quantity, 0) - COALESCE(m.computed_quantity, 0)) DESC, ft.name;

-- 5) Recompute chronological WAC from purchases and sales. This explains why
-- Solvent may show 322, 300.75, 343, etc.
WITH RECURSIVE ordered_tx AS (
  SELECT
    ft.id AS fuel_type_id,
    ft.name AS fuel_name,
    p.purchase_date AS tx_date,
    p.created_at,
    p.voucher_no,
    'purchase' AS tx_type,
    p.quantity,
    p.rate_per_unit,
    p.total_amount
  FROM public.purchases p
  JOIN public.fuel_types ft ON ft.id = p.fuel_type_id
  WHERE COALESCE(p.is_reversed, false) = false
    AND p.voucher_no NOT LIKE 'REV-%'

  UNION ALL

  SELECT
    ft.id,
    ft.name,
    s.sale_date,
    s.created_at,
    s.voucher_no,
    'sale',
    s.quantity,
    s.rate_per_unit,
    s.total_amount
  FROM public.sales s
  JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
  WHERE COALESCE(s.is_reversed, false) = false
    AND s.voucher_no NOT LIKE 'REV-%'
),
wac AS (
  SELECT
    row_number() OVER (
      PARTITION BY fuel_type_id
      ORDER BY tx_date, created_at, voucher_no
    ) AS rn,
    fuel_type_id,
    fuel_name,
    tx_date,
    created_at,
    voucher_no,
    tx_type,
    quantity,
    rate_per_unit,
    total_amount
  FROM ordered_tx
),
calc AS (
  SELECT
    rn,
    fuel_type_id,
    fuel_name,
    tx_date,
    created_at,
    voucher_no,
    tx_type,
    quantity,
    rate_per_unit,
    total_amount,
    CASE WHEN tx_type = 'purchase' THEN quantity ELSE -quantity END AS qty_after,
    CASE WHEN tx_type = 'purchase' THEN rate_per_unit ELSE 0 END AS avg_cost_after,
    CASE WHEN tx_type = 'sale' THEN ROUND(quantity * 0, 2) ELSE 0 END AS cogs_expected
  FROM wac
  WHERE rn = 1

  UNION ALL

  SELECT
    w.rn,
    w.fuel_type_id,
    w.fuel_name,
    w.tx_date,
    w.created_at,
    w.voucher_no,
    w.tx_type,
    w.quantity,
    w.rate_per_unit,
    w.total_amount,
    CASE
      WHEN w.tx_type = 'purchase' THEN c.qty_after + w.quantity
      ELSE c.qty_after - w.quantity
    END AS qty_after,
    CASE
      WHEN w.tx_type = 'purchase' AND (c.qty_after + w.quantity) > 0
        THEN ((c.qty_after * c.avg_cost_after) + w.total_amount) / (c.qty_after + w.quantity)
      WHEN w.tx_type = 'purchase'
        THEN w.rate_per_unit
      ELSE c.avg_cost_after
    END AS avg_cost_after,
    CASE
      WHEN w.tx_type = 'sale' THEN ROUND(w.quantity * c.avg_cost_after, 2)
      ELSE 0
    END AS cogs_expected
  FROM calc c
  JOIN wac w
    ON w.fuel_type_id = c.fuel_type_id
   AND w.rn = c.rn + 1
)
SELECT
  fuel_name,
  tx_date,
  voucher_no,
  tx_type,
  quantity,
  rate_per_unit,
  ROUND(qty_after, 2) AS qty_after,
  ROUND(avg_cost_after, 2) AS avg_cost_after,
  cogs_expected
FROM calc
WHERE fuel_name ILIKE '%solvent%'
ORDER BY tx_date, created_at, voucher_no;

-- 6) Compare recomputed final WAC with inventory table.
WITH RECURSIVE ordered_tx AS (
  SELECT ft.id AS fuel_type_id, ft.name AS fuel_name, p.purchase_date AS tx_date,
         p.created_at, p.voucher_no, 'purchase' AS tx_type, p.quantity,
         p.rate_per_unit, p.total_amount
  FROM public.purchases p
  JOIN public.fuel_types ft ON ft.id = p.fuel_type_id
  WHERE COALESCE(p.is_reversed, false) = false AND p.voucher_no NOT LIKE 'REV-%'
  UNION ALL
  SELECT ft.id, ft.name, s.sale_date, s.created_at, s.voucher_no, 'sale',
         s.quantity, s.rate_per_unit, s.total_amount
  FROM public.sales s
  JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
  WHERE COALESCE(s.is_reversed, false) = false AND s.voucher_no NOT LIKE 'REV-%'
),
wac AS (
  SELECT row_number() OVER (PARTITION BY fuel_type_id ORDER BY tx_date, created_at, voucher_no) AS rn, *
  FROM ordered_tx
),
calc AS (
  SELECT rn, fuel_type_id, fuel_name, tx_date, created_at, voucher_no, tx_type,
         quantity, rate_per_unit, total_amount,
         CASE WHEN tx_type = 'purchase' THEN quantity ELSE -quantity END AS qty_after,
         CASE WHEN tx_type = 'purchase' THEN rate_per_unit ELSE 0 END AS avg_cost_after
  FROM wac
  WHERE rn = 1
  UNION ALL
  SELECT w.rn, w.fuel_type_id, w.fuel_name, w.tx_date, w.created_at, w.voucher_no,
         w.tx_type, w.quantity, w.rate_per_unit, w.total_amount,
         CASE WHEN w.tx_type = 'purchase' THEN c.qty_after + w.quantity ELSE c.qty_after - w.quantity END,
         CASE
           WHEN w.tx_type = 'purchase' AND (c.qty_after + w.quantity) > 0
             THEN ((c.qty_after * c.avg_cost_after) + w.total_amount) / (c.qty_after + w.quantity)
           WHEN w.tx_type = 'purchase' THEN w.rate_per_unit
           ELSE c.avg_cost_after
         END
  FROM calc c
  JOIN wac w ON w.fuel_type_id = c.fuel_type_id AND w.rn = c.rn + 1
),
latest AS (
  SELECT DISTINCT ON (fuel_type_id)
    fuel_type_id,
    fuel_name,
    qty_after AS recomputed_qty,
    avg_cost_after AS recomputed_avg_cost
  FROM calc
  ORDER BY fuel_type_id, rn DESC
)
SELECT
  l.fuel_name,
  ROUND(l.recomputed_qty, 2) AS recomputed_qty,
  COALESCE(i.quantity, 0) AS cached_qty,
  ROUND(l.recomputed_avg_cost, 2) AS recomputed_avg_cost,
  COALESCE(i.avg_cost, 0) AS cached_avg_cost,
  ROUND((l.recomputed_qty * l.recomputed_avg_cost), 2) AS recomputed_value,
  ROUND((COALESCE(i.quantity, 0) * COALESCE(i.avg_cost, 0)), 2) AS cached_value,
  ROUND((l.recomputed_qty * l.recomputed_avg_cost) - (COALESCE(i.quantity, 0) * COALESCE(i.avg_cost, 0)), 2) AS value_drift
FROM latest l
LEFT JOIN public.inventory i ON i.fuel_type_id = l.fuel_type_id
ORDER BY ABS((l.recomputed_qty * l.recomputed_avg_cost) - (COALESCE(i.quantity, 0) * COALESCE(i.avg_cost, 0))) DESC;

-- 7) COGS ledger mismatch per sale: finds sales where posted COGS does not
-- match expected WAC at sale time.
WITH RECURSIVE ordered_tx AS (
  SELECT ft.id AS fuel_type_id, ft.name AS fuel_name, p.purchase_date AS tx_date,
         p.created_at, p.voucher_no, 'purchase' AS tx_type, p.quantity,
         p.rate_per_unit, p.total_amount
  FROM public.purchases p
  JOIN public.fuel_types ft ON ft.id = p.fuel_type_id
  WHERE COALESCE(p.is_reversed, false) = false AND p.voucher_no NOT LIKE 'REV-%'
  UNION ALL
  SELECT ft.id, ft.name, s.sale_date, s.created_at, s.voucher_no, 'sale',
         s.quantity, s.rate_per_unit, s.total_amount
  FROM public.sales s
  JOIN public.fuel_types ft ON ft.id = s.fuel_type_id
  WHERE COALESCE(s.is_reversed, false) = false AND s.voucher_no NOT LIKE 'REV-%'
),
wac AS (
  SELECT row_number() OVER (PARTITION BY fuel_type_id ORDER BY tx_date, created_at, voucher_no) AS rn, *
  FROM ordered_tx
),
calc AS (
  SELECT rn, fuel_type_id, fuel_name, tx_date, created_at, voucher_no, tx_type,
         quantity, rate_per_unit, total_amount,
         CASE WHEN tx_type = 'purchase' THEN quantity ELSE -quantity END AS qty_after,
         CASE WHEN tx_type = 'purchase' THEN rate_per_unit ELSE 0 END AS avg_cost_after,
         CASE WHEN tx_type = 'sale' THEN ROUND(quantity * 0, 2) ELSE 0 END AS expected_cogs
  FROM wac
  WHERE rn = 1
  UNION ALL
  SELECT w.rn, w.fuel_type_id, w.fuel_name, w.tx_date, w.created_at, w.voucher_no,
         w.tx_type, w.quantity, w.rate_per_unit, w.total_amount,
         CASE WHEN w.tx_type = 'purchase' THEN c.qty_after + w.quantity ELSE c.qty_after - w.quantity END,
         CASE
           WHEN w.tx_type = 'purchase' AND (c.qty_after + w.quantity) > 0
             THEN ((c.qty_after * c.avg_cost_after) + w.total_amount) / (c.qty_after + w.quantity)
           WHEN w.tx_type = 'purchase' THEN w.rate_per_unit
           ELSE c.avg_cost_after
         END,
         CASE WHEN w.tx_type = 'sale' THEN ROUND(w.quantity * c.avg_cost_after, 2) ELSE 0 END
  FROM calc c
  JOIN wac w ON w.fuel_type_id = c.fuel_type_id AND w.rn = c.rn + 1
),
posted AS (
  SELECT
    le.voucher_no,
    ROUND(SUM(le.debit_amount), 2) AS posted_cogs
  FROM public.ledger_entries le
  JOIN public.accounts a ON a.id = le.account_id
  WHERE (a.slug = 'cogs' OR a.code = '4100')
    AND COALESCE(le.is_reversed, false) = false
    AND le.voucher_no NOT LIKE 'REV-%'
  GROUP BY le.voucher_no
)
SELECT
  c.fuel_name,
  c.tx_date,
  c.voucher_no,
  c.quantity,
  ROUND(c.expected_cogs, 2) AS expected_cogs,
  COALESCE(p.posted_cogs, 0) AS posted_cogs,
  ROUND(COALESCE(p.posted_cogs, 0) - c.expected_cogs, 2) AS cogs_difference
FROM calc c
LEFT JOIN posted p ON p.voucher_no = c.voucher_no
WHERE c.tx_type = 'sale'
  AND ABS(COALESCE(p.posted_cogs, 0) - c.expected_cogs) > 1
ORDER BY ABS(COALESCE(p.posted_cogs, 0) - c.expected_cogs) DESC, c.tx_date;

-- 8) Full balance sheet output for the selected date.
SELECT *
FROM public.get_financial_position_v13(CURRENT_DATE);

-- 9) Trial balance control check for the selected date.
SELECT *
FROM public.get_trial_balance_v2(NULL, CURRENT_DATE)
WHERE account_code IN ('1200', '4100')
   OR account_name ILIKE '%inventory%'
   OR account_name ILIKE '%cost of goods%';

-- 10) Repair is available but do not run without backup/operator approval.
-- SELECT * FROM public.repair_inventory_gl_from_wac();

-- Fix management reporting for reversed transactions.
--
-- Reversal vouchers are audit artifacts: they should remain visible in account
-- statements, audit trails, and trial balance history. P&L and Balance Sheet
-- net-profit calculations should ignore them so a cancelled sale/purchase does
-- not appear as negative business performance.

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
    round(
      CASE
        WHEN a.account_type = 'income' THEN SUM(le.credit_amount - le.debit_amount)
        ELSE SUM(le.debit_amount - le.credit_amount)
      END,
      2
    )
  FROM public.accounts a
  JOIN public.ledger_entries le ON le.account_id = a.id
  WHERE a.account_type IN ('income', 'expense')
    AND le.posting_date BETWEEN p_start_date AND p_end_date
    AND (le.is_reversed = false OR le.is_reversed IS NULL)
    AND le.voucher_no NOT LIKE 'REV-%'
  GROUP BY a.id, a.name, a.account_type, a.sub_category, a.slug, a.code
  HAVING round(
    CASE
      WHEN a.account_type = 'income' THEN SUM(le.credit_amount - le.debit_amount)
      ELSE SUM(le.debit_amount - le.credit_amount)
    END,
    2
  ) <> 0
  ORDER BY 1, 4 DESC;
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
  SELECT COALESCE(SUM(
    CASE
      WHEN a.account_type = 'income' THEN le.credit_amount - le.debit_amount
      ELSE -(le.debit_amount - le.credit_amount)
    END
  ), 0)
  INTO v_net_profit
  FROM public.accounts a
  JOIN public.ledger_entries le ON le.account_id = a.id
  WHERE a.account_type IN ('income', 'expense')
    AND le.posting_date <= p_date
    AND (le.is_reversed = false OR le.is_reversed IS NULL)
    AND le.voucher_no NOT LIKE 'REV-%';

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

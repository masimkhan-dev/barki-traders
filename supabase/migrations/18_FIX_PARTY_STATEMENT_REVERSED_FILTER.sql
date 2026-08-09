-- Migration: 18_FIX_PARTY_STATEMENT_REVERSED_FILTER.sql
-- Pure Audit Trail Alignment for get_party_statement RPC:
-- Include ALL posted ledger entries in both opening balance B/F and period entries.
-- Preserves full accounting auditability while maintaining exact mathematical accuracy across all date ranges.

CREATE OR REPLACE FUNCTION public.get_party_statement(
  p_party_id UUID,
  p_start_date DATE DEFAULT '2000-01-01'::DATE,
  p_end_date DATE DEFAULT '2099-12-31'::DATE
)
RETURNS TABLE(
  posting_date DATE, 
  voucher_no TEXT, 
  particulars TEXT, 
  details TEXT, 
  contra_mode TEXT, 
  qty NUMERIC, 
  rate NUMERIC, 
  debit NUMERIC, 
  credit NUMERIC, 
  running_balance NUMERIC, 
  fuel_name TEXT, 
  is_reversed_entry BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_opening NUMERIC := 0;
BEGIN
  -- Opening balance includes ALL posted ledger entries prior to start date for full audit continuity
  SELECT COALESCE(p.opening_balance, 0) + COALESCE((
    SELECT SUM(le.debit_amount - le.credit_amount)
    FROM public.ledger_entries le
    WHERE le.party_id = p_party_id
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

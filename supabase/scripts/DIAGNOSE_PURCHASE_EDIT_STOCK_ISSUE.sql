WITH params AS (SELECT 'PUR-20260522-001'::text AS voucher_no)
SELECT
  p.voucher_no,
  EXISTS(SELECT 1 FROM purchases x WHERE x.voucher_no = p.voucher_no) AS purchase_row_exists,
  EXISTS(SELECT 1 FROM ledger_entries x WHERE x.voucher_no = p.voucher_no) AS ledger_exists
FROM params p;
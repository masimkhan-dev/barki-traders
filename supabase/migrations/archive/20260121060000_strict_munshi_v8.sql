-- MASTER REPAIR (V8): THE STRICT MUNSHI KHATA
-- This script enforces the "Simplified Statement" rule: Single Row per Voucher.
BEGIN;

-- 1. DROP ALL VARIANTS TO PREVENT RETURN TYPE ERRORS
DROP FUNCTION IF EXISTS get_party_statement(UUID, DATE, DATE);
DROP FUNCTION IF EXISTS get_party_statement(UUID);
DROP FUNCTION IF EXISTS get_party_product_summary(UUID, DATE, DATE);
DROP FUNCTION IF EXISTS get_party_product_summary(UUID);
DROP FUNCTION IF EXISTS get_munshi_daily_stats(DATE);

-- 2. THE MUNSHI STATEMENT (COLLAPSED & HUMAN-READABLE)
CREATE OR REPLACE FUNCTION get_party_statement(
  p_party_id UUID, 
  p_start_date DATE, 
  p_end_date DATE
)
RETURNS TABLE (
  posting_date DATE, 
  voucher_no TEXT, 
  particulars TEXT, 
  debit NUMERIC, 
  credit NUMERIC, 
  running_balance NUMERIC
) AS $$
DECLARE v_opening_balance NUMERIC;
BEGIN
    -- Opening Balance calculation (Past Ledger Entries + Party's opening)
    SELECT 
      COALESCE(pa.opening_balance, 0) + COALESCE((
        SELECT SUM(le_start.debit_amount - le_start.credit_amount) 
        FROM ledger_entries le_start 
        WHERE le_start.party_id = p_party_id 
        AND le_start.posting_date < p_start_date
      ), 0) 
    INTO v_opening_balance 
    FROM parties pa WHERE pa.id = p_party_id;

    -- Row 1: Opening Balance Row
    RETURN QUERY 
    SELECT 
      (p_start_date - INTERVAL '1 day')::DATE, 
      'OPEN'::TEXT, 
      'Opening Balance'::TEXT, 
      CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0.0 END, 
      CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0.0 END, 
      v_opening_balance;

    -- Row 2+: Collapsed Transactions
    -- Grouping by voucher_no and party_id to ensure exactly ONE row per transaction.
    RETURN QUERY 
    WITH raw_entries AS (
        SELECT 
            le.posting_date, 
            le.voucher_no, 
            -- Mapping logical names
            CASE 
                WHEN le.voucher_type = 'sale' THEN 'Sale'
                WHEN le.voucher_type = 'purchase' THEN 'Purchase'
                WHEN le.voucher_type = 'payment' AND le.debit_amount > 0 THEN 'Cash Paid'
                WHEN le.voucher_type = 'payment' AND le.credit_amount > 0 THEN 'Cash Received'
                ELSE le.narration 
            END as particulars,
            SUM(le.debit_amount) as dr,
            SUM(le.credit_amount) as cr,
            MIN(le.created_at) as sort_key
        FROM ledger_entries le 
        WHERE le.party_id = p_party_id 
        AND le.posting_date >= p_start_date 
        AND le.posting_date <= p_end_date 
        GROUP BY le.posting_date, le.voucher_no, le.voucher_type, le.narration, le.debit_amount, le.credit_amount, le.created_at
    ),
    collapsed AS (
        SELECT 
            r.posting_date,
            r.voucher_no,
            MAX(r.particulars) as particulars,
            SUM(r.dr) as debit,
            SUM(r.cr) as credit,
            -- Running balance logic: Debit increases, Credit decreases
            SUM(SUM(r.dr - r.cr)) OVER (ORDER BY r.posting_date, MIN(r.sort_key)) + v_opening_balance as running_balance
        FROM raw_entries r
        GROUP BY r.posting_date, r.voucher_no
    )
    SELECT * FROM collapsed ORDER BY posting_date, voucher_no;
END; $$ LANGUAGE plpgsql;

-- 3. THE MUNSHI PRODUCT SUMMARY (QTY ONLY)
CREATE OR REPLACE FUNCTION get_party_product_summary(
  p_party_id UUID, 
  p_start_date DATE, 
  p_end_date DATE
)
RETURNS TABLE (fuel_name TEXT, total_qty NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        f.name, 
        SUM(COALESCE(s.quantity, 0) + COALESCE(pur.quantity, 0)) as qty
    FROM fuel_types f
    LEFT JOIN sales s ON s.fuel_type_id = f.id AND s.party_id = p_party_id AND s.sale_date >= p_start_date AND s.sale_date <= p_end_date
    LEFT JOIN purchases pur ON pur.fuel_type_id = f.id AND pur.party_id = p_party_id AND pur.purchase_date >= p_start_date AND pur.purchase_date <= p_end_date
    GROUP BY f.name
    HAVING SUM(COALESCE(s.quantity, 0) + COALESCE(pur.quantity, 0)) > 0;
END; $$ LANGUAGE plpgsql;

COMMIT;
NOTIFY pgrst, 'reload config';

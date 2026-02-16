-- MASTER REPAIR (V7): THE MUNSHI STANDARD
-- This script fixes the Statement, Dashboard, and Accounting Logic to be strictly human-readable.
BEGIN;

-- 1. DROP ALL PREVIOUS VERSIONS
DROP FUNCTION IF EXISTS get_party_statement(uuid, date, date);
DROP FUNCTION IF EXISTS get_party_product_summary(uuid, date, date);
DROP FUNCTION IF EXISTS get_daily_summary(date);

-- 2. THE CLEAN PARTY STATEMENT (SINGLE ROW PER VOUCHER)
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
    -- Opening Balance calculation (Sum of all past transactions + Party's base opening)
    SELECT 
      COALESCE(pa.opening_balance, 0) + COALESCE((
        SELECT SUM(le_start.debit_amount - le_start.credit_amount) 
        FROM ledger_entries le_start 
        WHERE le_start.party_id = p_party_id 
        AND le_start.posting_date < p_start_date
      ), 0) 
    INTO v_opening_balance 
    FROM parties pa WHERE pa.id = p_party_id;

    -- Row 1: Opening Balance
    RETURN QUERY 
    SELECT 
      (p_start_date - INTERVAL '1 day')::DATE, 
      'OPEN'::TEXT, 
      'Opening Balance'::TEXT, 
      CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0 END, 
      CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0 END, 
      v_opening_balance;

    -- Row 2+: Human-Readable Transactions
    -- We filter only rows where party_id is present, ensuring one row per voucher per party.
    RETURN QUERY 
    WITH entries AS (
        SELECT 
            le.posting_date as dt, 
            le.voucher_no as vno, 
            COALESCE(le.narration, '') as narr, 
            le.debit_amount as dr,
            le.credit_amount as cr,
            SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at) + v_opening_balance as bal
        FROM ledger_entries le 
        WHERE le.party_id = p_party_id 
        AND le.posting_date >= p_start_date 
        AND le.posting_date <= p_end_date 
        ORDER BY le.posting_date, le.created_at
    ) 
    SELECT * FROM entries;
END; $$ LANGUAGE plpgsql;

-- 3. THE CLEAN PRODUCT SUMMARY (BELOW TABLE)
CREATE OR REPLACE FUNCTION get_party_product_summary(
  p_party_id UUID, 
  p_start_date DATE, 
  p_end_date DATE
)
RETURNS TABLE (fuel_name TEXT, total_qty_sale NUMERIC, total_qty_purchase NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        f.name, 
        SUM(COALESCE(s.quantity, 0)) as sale_qty,
        SUM(COALESCE(pur.quantity, 0)) as purchase_qty
    FROM fuel_types f
    LEFT JOIN sales s ON s.fuel_type_id = f.id AND s.party_id = p_party_id AND s.sale_date >= p_start_date AND s.sale_date <= p_end_date
    LEFT JOIN purchases pur ON pur.fuel_type_id = f.id AND pur.party_id = p_party_id AND pur.purchase_date >= p_start_date AND pur.purchase_date <= p_end_date
    GROUP BY f.name
    HAVING SUM(COALESCE(s.quantity, 0)) > 0 OR SUM(COALESCE(pur.quantity, 0)) > 0;
END;
$$ LANGUAGE plpgsql;

-- 4. CLEAN DASHBOARD SUMMARY (SIMPLE ENGLISH)
CREATE OR REPLACE FUNCTION get_munshi_daily_stats(p_date DATE)
RETURNS TABLE (
    total_sales_amt NUMERIC,
    total_sales_qty NUMERIC,
    total_purchase_amt NUMERIC,
    total_purchase_qty NUMERIC,
    cash_received NUMERIC,
    cash_paid NUMERIC,
    market_balance NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        (SELECT COALESCE(SUM(total_amount), 0) FROM sales WHERE sale_date = p_date),
        (SELECT COALESCE(SUM(quantity), 0) FROM sales WHERE sale_date = p_date),
        (SELECT COALESCE(SUM(total_amount), 0) FROM purchases WHERE purchase_date = p_date),
        (SELECT COALESCE(SUM(quantity), 0) FROM purchases WHERE purchase_date = p_date),
        (SELECT COALESCE(SUM(credit_amount), 0) FROM ledger_entries WHERE voucher_type = 'payment' AND posting_date = p_date AND party_id IS NOT NULL),
        (SELECT COALESCE(SUM(debit_amount), 0) FROM ledger_entries WHERE voucher_type = 'payment' AND posting_date = p_date AND party_id IS NOT NULL),
        (SELECT COALESCE(SUM(current_balance), 0) FROM parties)
    ;
END;
$$ LANGUAGE plpgsql;

COMMIT;
NOTIFY pgrst, 'reload config';

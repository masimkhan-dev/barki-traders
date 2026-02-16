-- FINAL MUNSHI BACKEND OPTIMIZATIONS
BEGIN;

-- 1. UPDATE GET DAILY SUMMARY: Add Market Balance
DROP FUNCTION IF EXISTS get_daily_summary(date);
CREATE OR REPLACE FUNCTION get_daily_summary(target_date DATE)
RETURNS json AS $$
DECLARE
    result json;
BEGIN
    SELECT json_build_object(
        'total_sales', COALESCE((SELECT SUM(total_amount) FROM sales WHERE sale_date = target_date), 0),
        'total_sales_qty', COALESCE((SELECT SUM(quantity) FROM sales WHERE sale_date = target_date), 0),
        'total_purchases', COALESCE((SELECT SUM(total_amount) FROM purchases WHERE purchase_date = target_date), 0),
        'total_purchases_qty', COALESCE((SELECT SUM(quantity) FROM purchases WHERE purchase_date = target_date), 0),
        'cash_in', COALESCE((SELECT SUM(debit_amount) FROM ledger_entries le JOIN accounts a ON le.account_id = a.id WHERE a.code IN ('1000', '1010') AND posting_date = target_date), 0),
        'cash_out', COALESCE((SELECT SUM(credit_amount) FROM ledger_entries le JOIN accounts a ON le.account_id = a.id WHERE a.code IN ('1000', '1010') AND posting_date = target_date), 0),
        'market_balance', COALESCE((SELECT SUM(current_balance) FROM parties), 0)
    ) INTO result;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- 2. UPDATE GET PARTY PRODUCT SUMMARY: Add Date Filtering
DROP FUNCTION IF EXISTS get_party_product_summary(uuid);
DROP FUNCTION IF EXISTS get_party_product_summary(uuid, date, date);
CREATE OR REPLACE FUNCTION get_party_product_summary(p_party_id UUID, p_start_date DATE DEFAULT '2000-01-01', p_end_date DATE DEFAULT '2099-12-31')
RETURNS TABLE (fuel_name TEXT, total_qty NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT f.name, SUM(q.qty)
    FROM (
        SELECT fuel_type_id, SUM(quantity) as qty FROM sales WHERE party_id = p_party_id AND sale_date >= p_start_date AND sale_date <= p_end_date GROUP BY fuel_type_id
        UNION ALL
        SELECT fuel_type_id, SUM(quantity) as qty FROM purchases WHERE party_id = p_party_id AND purchase_date >= p_start_date AND purchase_date <= p_end_date GROUP BY fuel_type_id
    ) q
    JOIN fuel_types f ON q.fuel_type_id = f.id
    GROUP BY f.name;
END;
$$ LANGUAGE plpgsql;

COMMIT;

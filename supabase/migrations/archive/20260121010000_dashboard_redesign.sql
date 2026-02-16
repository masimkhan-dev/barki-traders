
-- MUNSHI DASHBOARD REDESIGN BACKEND
BEGIN;

-- 1. Optimized Daily Summary (5 key stats)
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
        'cash_received', COALESCE((SELECT SUM(amount) FROM payments WHERE payment_type = 'receipt' AND payment_date = target_date), 0),
        'cash_paid', COALESCE((SELECT SUM(amount) FROM payments WHERE payment_type = 'payment' AND payment_date = target_date), 0),
        'market_balance', COALESCE((SELECT SUM(current_balance) FROM parties), 0)
    ) INTO result;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- 2. New Dashboard Feed RPC
DROP FUNCTION IF EXISTS get_dashboard_feed(integer);
CREATE OR REPLACE FUNCTION get_dashboard_feed(p_limit INTEGER DEFAULT 20)
RETURNS TABLE (
    id UUID,
    date DATE,
    voucher_no TEXT,
    party_name TEXT,
    description TEXT,
    paid NUMERIC,
    received NUMERIC,
    running_balance NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    WITH latest_entries AS (
        SELECT 
            le.id as entry_id,
            le.posting_date,
            le.voucher_no,
            p.name as party_name,
            le.narration as description,
            le.debit_amount as paid,
            le.credit_amount as received,
            le.party_id,
            le.created_at
        FROM ledger_entries le
        JOIN parties p ON le.party_id = p.id
        ORDER BY le.posting_date DESC, le.created_at DESC
        LIMIT p_limit
    )
    SELECT 
        e.entry_id,
        e.posting_date,
        e.voucher_no,
        e.party_name,
        e.description,
        e.paid,
        e.received,
        (
            SELECT COALESCE(SUM(le2.debit_amount - le2.credit_amount), 0)
            FROM ledger_entries le2
            WHERE le2.party_id = e.party_id
            AND (le2.posting_date < e.posting_date OR (le2.posting_date = e.posting_date AND le2.created_at <= e.created_at))
        ) + (SELECT COALESCE(opening_balance, 0) FROM parties WHERE id = e.party_id) as running_balance
    FROM latest_entries e
    ORDER BY e.posting_date DESC, e.created_at DESC;
END;
$$ LANGUAGE plpgsql;

COMMIT;

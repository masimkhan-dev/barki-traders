-- MASTER REPAIR SCRIPT (V3): TOTAL RESET OF MUNSHI FUNCTIONS
-- This script nukes old functions and creates fresh ones with "munshi_" prefix to avoid conflicts.
BEGIN;

-- 1. DROP ALL POTENTIAL CONFLICTS
DROP FUNCTION IF EXISTS get_trial_balance(date, date);
DROP FUNCTION IF EXISTS get_trial_balance_v2(date, date);
DROP FUNCTION IF EXISTS get_balance_sheet(date);
DROP FUNCTION IF EXISTS get_party_statement(uuid);
DROP FUNCTION IF EXISTS get_party_statement(uuid, date, date);
DROP FUNCTION IF EXISTS get_party_product_summary(uuid);
DROP FUNCTION IF EXISTS get_party_product_summary(uuid, date, date);
DROP FUNCTION IF EXISTS get_daily_summary(date);
DROP FUNCTION IF EXISTS get_dashboard_feed(integer);

-- 2. RECREATE: DAILY SUMMARY
CREATE OR REPLACE FUNCTION get_daily_summary(p_target_date DATE)
RETURNS json AS $$
DECLARE result json;
BEGIN
    SELECT json_build_object(
        'total_sales', COALESCE((SELECT SUM(total_amount) FROM sales WHERE sale_date = p_target_date), 0),
        'total_sales_qty', COALESCE((SELECT SUM(quantity) FROM sales WHERE sale_date = p_target_date), 0),
        'total_purchases', COALESCE((SELECT SUM(total_amount) FROM purchases WHERE purchase_date = p_target_date), 0),
        'total_purchases_qty', COALESCE((SELECT SUM(quantity) FROM purchases WHERE purchase_date = p_target_date), 0),
        'cash_received', COALESCE((SELECT SUM(amount) FROM payments WHERE payment_type = 'receipt' AND payment_date = p_target_date), 0),
        'cash_paid', COALESCE((SELECT SUM(amount) FROM payments WHERE payment_type = 'payment' AND payment_date = p_target_date), 0),
        'market_balance', COALESCE((SELECT SUM(current_balance) FROM parties), 0)
    ) INTO result;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- 3. RECREATE: DASHBOARD FEED
CREATE OR REPLACE FUNCTION get_dashboard_feed(p_limit INTEGER DEFAULT 20)
RETURNS TABLE (id UUID, date DATE, voucher_no TEXT, party_name TEXT, description TEXT, paid NUMERIC, received NUMERIC, running_balance NUMERIC) AS $$
BEGIN
    RETURN QUERY
    WITH latest_entries AS (
        SELECT le.id as entry_id, le.posting_date, le.voucher_no, p.name as party_name, le.narration as description, le.debit_amount as paid, le.credit_amount as received, le.party_id, le.created_at
        FROM ledger_entries le JOIN parties p ON le.party_id = p.id
        ORDER BY le.posting_date DESC, le.created_at DESC LIMIT p_limit
    )
    SELECT e.entry_id, e.posting_date, e.voucher_no, e.party_name, e.description, e.paid, e.received,
        (SELECT COALESCE(SUM(le2.debit_amount - le2.credit_amount), 0) FROM ledger_entries le2 WHERE le2.party_id = e.party_id AND (le2.posting_date < e.posting_date OR (le2.posting_date = e.posting_date AND le2.created_at <= e.created_at))) + (SELECT COALESCE(opening_balance, 0) FROM parties WHERE id = e.party_id)
    FROM latest_entries e ORDER BY e.posting_date DESC, e.created_at DESC;
END;
$$ LANGUAGE plpgsql;

-- 4. RECREATE: PARTY STATEMENT
CREATE OR REPLACE FUNCTION get_party_statement(p_party_id UUID, p_start_date DATE, p_end_date DATE)
RETURNS TABLE (posting_date DATE, voucher_no TEXT, particulars TEXT, details TEXT, contra_mode TEXT, qty NUMERIC, rate NUMERIC, sale_purchase_amount NUMERIC, payment_received NUMERIC, payment_made NUMERIC, running_balance NUMERIC) AS $$
DECLARE v_opening_balance NUMERIC;
BEGIN
    SELECT COALESCE(p.opening_balance, 0) + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p_party_id AND posting_date < p_start_date), 0) INTO v_opening_balance FROM parties p WHERE p.id = p_party_id;
    RETURN QUERY SELECT (p_start_date - INTERVAL '1 day')::DATE, 'OPEN'::TEXT, 'Start Balance'::TEXT, 'Brought Forward'::TEXT, '--'::TEXT, NULL::NUMERIC, NULL::NUMERIC, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC, v_opening_balance;
    RETURN QUERY WITH entries AS (
        SELECT le.posting_date, le.voucher_no, le.narration as particulars, le.voucher_type as details, (SELECT COALESCE(part.name, acc.name) FROM ledger_entries le2 LEFT JOIN parties part ON le2.party_id = part.id LEFT JOIN accounts acc ON le2.account_id = acc.id WHERE le2.voucher_no = le.voucher_no AND le2.id != le.id LIMIT 1) as contra_mode, NULL::NUMERIC, NULL::NUMERIC,
        CASE WHEN le.voucher_type IN ('sale', 'purchase') THEN (le.debit_amount + le.credit_amount) ELSE 0 END,
        CASE WHEN le.voucher_type = 'munshi_voucher' AND le.credit_amount > 0 THEN le.credit_amount ELSE 0 END,
        CASE WHEN le.voucher_type = 'munshi_voucher' AND le.debit_amount > 0 THEN le.debit_amount ELSE 0 END,
        SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at) + v_opening_balance
        FROM ledger_entries le WHERE le.party_id = p_party_id AND le.posting_date >= p_start_date AND le.posting_date <= p_end_date ORDER BY le.posting_date, le.created_at
    ) SELECT * FROM entries;
END; $$ LANGUAGE plpgsql;

-- 5. RECREATE: PARTY PRODUCT SUMMARY
CREATE OR REPLACE FUNCTION get_party_product_summary(p_party_id UUID, p_start_date DATE, p_end_date DATE)
RETURNS TABLE (fuel_name TEXT, total_qty NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT f.name, SUM(q.qty)
    FROM (
        SELECT fuel_type_id, SUM(quantity) as qty FROM sales WHERE party_id = p_party_id AND sale_date >= p_start_date AND sale_date <= p_end_date GROUP BY fuel_type_id
        UNION ALL
        SELECT fuel_type_id, SUM(quantity) as qty FROM purchases WHERE party_id = p_party_id AND purchase_date >= p_start_date AND purchase_date <= p_end_date GROUP BY fuel_type_id
    ) q JOIN fuel_types f ON q.fuel_type_id = f.id GROUP BY f.name;
END;
$$ LANGUAGE plpgsql;

-- 6. RECREATE: TRIAL BALANCE & BALANCE SHEET
CREATE OR REPLACE FUNCTION get_trial_balance_v2(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (account_code TEXT, account_name TEXT, opening_balance NUMERIC, debit_total NUMERIC, credit_total NUMERIC, closing_balance NUMERIC) AS $$
BEGIN
    RETURN QUERY
    WITH base_data AS (
        SELECT a.code, a.name, COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date < p_start_date), 0) as opening, COALESCE((SELECT SUM(debit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) as debit, COALESCE((SELECT SUM(credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) as credit FROM accounts a WHERE a.is_active = true
        UNION ALL
        SELECT CASE WHEN p.type = 'customer' THEN 'CUST' ELSE 'SUPP' END, p.name, COALESCE(p.opening_balance, 0) + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date < p_start_date), 0), COALESCE((SELECT SUM(debit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0), COALESCE((SELECT SUM(credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date >= p_start_date AND posting_date <= p_end_date), 0) FROM parties p WHERE p.is_active = true
    )
    SELECT b.code, b.name, b.opening, b.debit, b.credit, (b.opening + b.debit - b.credit) FROM base_data b WHERE ABS(b.opening) > 0 OR ABS(b.debit) > 0 OR ABS(b.credit) > 0;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_balance_sheet(p_date DATE)
RETURNS TABLE (category TEXT, sub_category TEXT, account_name TEXT, balance NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT 'ASSETS'::TEXT, a.account_type::TEXT, a.name, COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date <= p_date), 0) FROM accounts a WHERE a.account_type = 'asset' AND a.is_active = true
    UNION ALL
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name, (p.opening_balance + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date <= p_date), 0)) FROM parties p WHERE p.is_active = true AND (p.opening_balance + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date <= p_date), 0)) > 0
    UNION ALL
    SELECT 'LIABILITIES'::TEXT, a.account_type::TEXT, a.name, ABS(COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date <= p_date), 0)) FROM accounts a WHERE a.account_type = 'liability' AND a.is_active = true
    UNION ALL
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name, ABS(p.opening_balance + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date <= p_date), 0)) FROM parties p WHERE p.is_active = true AND (p.opening_balance + COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p.id AND posting_date <= p_date), 0)) < 0
    UNION ALL
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name, ABS(COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE account_id = a.id AND posting_date <= p_date), 0)) FROM accounts a WHERE a.account_type = 'equity' AND a.is_active = true
    UNION ALL
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Inappropriate Profit'::TEXT, ABS(COALESCE((SELECT SUM(credit_amount - debit_amount) FROM ledger_entries le JOIN accounts a ON le.account_id = a.id WHERE a.account_type IN ('income', 'expense') AND posting_date <= p_date), 0));
END; $$ LANGUAGE plpgsql;

COMMIT;
NOTIFY pgrst, 'reload config';

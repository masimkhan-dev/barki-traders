-- Enhanced Ledger Statements & Dashboard Metrics
-- This migration updates statement RPCs to include Qty/Rate and adds monthly metrics

-- 1. Enhanced Customer Statement (with Qty/Rate/Fuel)
CREATE OR REPLACE FUNCTION get_customer_ledger_statement(target_customer_id UUID)
RETURNS TABLE (
    entry_id UUID,
    posting_date DATE,
    voucher_no TEXT,
    voucher_type TEXT,
    narration TEXT,
    debit_amount NUMERIC,
    credit_amount NUMERIC,
    running_balance NUMERIC,
    -- New columns for detail view
    quantity NUMERIC,
    rate NUMERIC,
    fuel_type TEXT
) 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        le.id as entry_id,
        le.posting_date,
        le.voucher_no,
        le.voucher_type::text,
        COALESCE(le.narration, 
            CASE 
                WHEN s.id IS NOT NULL THEN 'Sale - ' || COALESCE(s.notes, '')
                WHEN p.id IS NOT NULL THEN 'Payment - ' || COALESCE(p.payment_method, '')
                ELSE 'Transaction'
            END
        ) as narration,
        le.debit_amount,
        le.credit_amount,
        0::numeric as running_balance,
        -- Details from Sales
        s.quantity,
        s.rate_per_unit as rate,
        ft.name as fuel_type
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    LEFT JOIN sales s ON le.reference_type = 'sale' AND le.reference_id = s.id
    LEFT JOIN fuel_types ft ON s.fuel_type_id = ft.id
    LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
    WHERE 
        a.code IN ('1100', '2100')
        AND (
            (s.customer_id = target_customer_id)
            OR 
            (p.party_id = target_customer_id AND p.party_type = 'customer')
        )
    ORDER BY le.posting_date ASC, le.created_at ASC;
END;
$$;

-- 2. Enhanced Supplier Statement
CREATE OR REPLACE FUNCTION get_supplier_ledger_statement(target_supplier_id UUID)
RETURNS TABLE (
    entry_id UUID,
    posting_date DATE,
    voucher_no TEXT,
    voucher_type TEXT,
    narration TEXT,
    debit_amount NUMERIC,
    credit_amount NUMERIC,
    running_balance NUMERIC,
    quantity NUMERIC,
    rate NUMERIC,
    fuel_type TEXT
) 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        le.id as entry_id,
        le.posting_date,
        le.voucher_no,
        le.voucher_type::text,
        COALESCE(le.narration,
            CASE 
                WHEN pur.id IS NOT NULL THEN 'Purchase - ' || COALESCE(pur.notes, '')
                WHEN p.id IS NOT NULL THEN 'Payment - ' || COALESCE(p.payment_method, '')
                ELSE 'Transaction'
            END
        ) as narration,
        le.debit_amount,
        le.credit_amount,
        0::numeric as running_balance,
        pur.quantity,
        pur.rate_per_unit as rate,
        ft.name as fuel_type
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    LEFT JOIN purchases pur ON le.reference_type = 'purchase' AND le.reference_id = pur.id
    LEFT JOIN fuel_types ft ON pur.fuel_type_id = ft.id
    LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
    WHERE 
        a.code IN ('2000', '1110')
        AND (
            (pur.supplier_id = target_supplier_id)
            OR 
            (p.party_id = target_supplier_id AND p.party_type = 'supplier')
        )
    ORDER BY le.posting_date ASC, le.created_at ASC;
END;
$$;

-- 3. Monthly Metrics for Dashboard Chart
CREATE OR REPLACE FUNCTION get_monthly_metrics(start_date DATE, end_date DATE)
RETURNS TABLE (
    day_date DATE,
    total_sales NUMERIC,
    total_purchases NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    WITH date_series AS (
        SELECT generate_series(start_date, end_date, '1 day'::interval)::date as d
    )
    SELECT 
        ds.d,
        COALESCE((
            SELECT SUM(total_amount) 
            FROM sales 
            WHERE sale_date = ds.d
        ), 0) as total_sales,
        COALESCE((
            SELECT SUM(total_amount) 
            FROM purchases 
            WHERE purchase_date = ds.d
        ), 0) as total_purchases
    FROM date_series ds;
END;
$$;

-- 4. Top Customers Widget
CREATE OR REPLACE FUNCTION get_top_customers_balances(limit_count INT DEFAULT 5)
RETURNS TABLE (
    name TEXT,
    balance NUMERIC
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
    SELECT 
        c.name,
        (
            c.opening_balance + 
            COALESCE((
                SELECT SUM(
                    CASE 
                        WHEN le.debit_amount > 0 THEN le.debit_amount 
                        ELSE -le.credit_amount 
                    END
                )
                FROM ledger_entries le
                LEFT JOIN sales s ON le.reference_type = 'sale' AND le.reference_id = s.id
                LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
                WHERE (s.customer_id = c.id OR (p.party_id = c.id AND p.party_type = 'customer'))
                AND le.account_id IN (SELECT id FROM accounts WHERE code IN ('1100', '2100'))
            ), 0)
        ) as current_balance
    FROM customers c
    WHERE c.is_active = true
    ORDER BY current_balance DESC
    LIMIT limit_count;
END;
$$;

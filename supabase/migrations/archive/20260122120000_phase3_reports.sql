-- PHASE 3: BUSINESS REPORTS (ACTIVITY LISTS) - POLISHED
-- -----------------------------------------------------
-- This migration adds dedicated RPCs for granular business reporting.
-- These reports are designed to be "Flat Lists" for export/viewing.
-- They abstract the underlying table joins and provide consistent naming/formatting.

BEGIN;

-- 1. SALES REPORT
-- Detailed list of all sales within a date range
CREATE OR REPLACE FUNCTION public.get_sales_report(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    sale_date DATE, 
    voucher_no TEXT, 
    party_name TEXT, 
    fuel_name TEXT, 
    quantity NUMERIC, 
    rate NUMERIC, 
    total_amount NUMERIC,
    is_credit BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        s.sale_date,
        s.voucher_no,
        coalesce(p.name, 'Unknown Party') as party_name,
        f.name as fuel_name,
        ROUND(s.quantity, 2) as quantity,
        ROUND(s.rate_per_unit, 2) as rate,
        ROUND(s.total_amount, 2) as total_amount,
        s.is_credit -- Metadata
    FROM sales s
    LEFT JOIN parties p ON s.party_id = p.id
    LEFT JOIN fuel_types f ON s.fuel_type_id = f.id
    WHERE s.sale_date BETWEEN p_start_date AND p_end_date
    ORDER BY s.sale_date DESC, s.created_at DESC;
END;
$$ LANGUAGE plpgsql;


-- 2. PURCHASE REPORT
-- Detailed list of all purchases (procurements)
CREATE OR REPLACE FUNCTION public.get_purchase_report(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    purchase_date DATE, 
    voucher_no TEXT, 
    party_name TEXT, -- Unified naming (was supplier_name)
    fuel_name TEXT, 
    quantity NUMERIC, 
    rate NUMERIC, 
    total_amount NUMERIC,
    status TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        pub.purchase_date,
        pub.voucher_no,
        coalesce(p.name, 'Unknown Supplier') as party_name,
        f.name as fuel_name,
        ROUND(pub.quantity, 2) as quantity,
        ROUND(pub.rate_per_unit, 2) as rate,
        ROUND(pub.total_amount, 2) as total_amount,
        CASE 
            WHEN pub.is_paid_now THEN 'Cash Purchase' 
            ELSE 'Credit Purchase' 
        END as status
    FROM purchases pub
    LEFT JOIN parties p ON pub.party_id = p.id
    LEFT JOIN fuel_types f ON pub.fuel_type_id = f.id
    WHERE pub.purchase_date BETWEEN p_start_date AND p_end_date
    ORDER BY pub.purchase_date DESC, pub.created_at DESC;
END;
$$ LANGUAGE plpgsql;


-- 3. CASH FLOW REPORT (PAYMENTS & RECEIPTS)
-- Unified list of cash movement linked to parties
CREATE OR REPLACE FUNCTION public.get_cash_flow_report(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    payment_date DATE, 
    voucher_no TEXT, 
    party_name TEXT, 
    type TEXT, -- 'IN' or 'OUT'
    amount NUMERIC,
    method TEXT,
    notes TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        pay.payment_date,
        pay.voucher_no,
        coalesce(p.name, 'Unknown Party') as party_name,
        CASE 
            WHEN pay.payment_type = 'receipt' THEN 'IN' 
            ELSE 'OUT' 
        END as type,
        ROUND(pay.amount, 2) as amount,
        pay.method,
        COALESCE(pay.notes, '') as notes
    FROM payments pay
    LEFT JOIN parties p ON pay.party_id = p.id
    WHERE pay.payment_date BETWEEN p_start_date AND p_end_date
    ORDER BY pay.payment_date DESC, pay.created_at DESC;
END;
$$ LANGUAGE plpgsql;

COMMIT;

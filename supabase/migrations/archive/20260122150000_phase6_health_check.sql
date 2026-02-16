-- PHASE 6: SYSTEM HEALTH & DIAGNOSTICS (UAT VALIDATION) - POLISHED
-- -----------------------------------------------------
-- This RPC provides a comprehensive health check of the accounting system.
-- Run this daily or before reports to ensure data integrity.
-- Includes Severity Levels and Timestamp.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_system_health()
RETURNS JSON AS $$
DECLARE
    v_imbalanced_count INT;
    v_sync_error_count INT;
    v_negative_stock_count INT;
    v_imbalanced_data JSON;
    v_sync_data JSON;
    v_stock_data JSON;
BEGIN
    -- 1. CHECK IMBALANCED VOUCHERS (CRITICAL: Debits != Credits)
    SELECT json_agg(t) INTO v_imbalanced_data
    FROM (
        SELECT voucher_no, SUM(debit_amount) as dr, SUM(credit_amount) as cr
        FROM ledger_entries
        GROUP BY voucher_no
        HAVING ABS(SUM(debit_amount) - SUM(credit_amount)) > 0.01
    ) t;

    SELECT COUNT(*) INTO v_imbalanced_count
    FROM (
        SELECT voucher_no FROM ledger_entries GROUP BY voucher_no HAVING ABS(SUM(debit_amount) - SUM(credit_amount)) > 0.01
    ) c;


    -- 2. CHECK PARTY BALANCE SYNC (HIGH: Party Table vs Ledger Sum)
    SELECT json_agg(t) INTO v_sync_data
    FROM (
        SELECT 
            p.name, 
            p.current_balance as table_balance, 
            COALESCE(SUM(le.debit_amount - le.credit_amount), 0) + p.opening_balance as ledger_balance
        FROM parties p
        LEFT JOIN ledger_entries le ON p.id = le.party_id
        GROUP BY p.id
        HAVING ABS(p.current_balance - (COALESCE(SUM(le.debit_amount - le.credit_amount), 0) + p.opening_balance)) > 0.01
    ) t;

    SELECT COUNT(*) INTO v_sync_error_count
    FROM (
        SELECT p.id
        FROM parties p
        LEFT JOIN ledger_entries le ON p.id = le.party_id
        GROUP BY p.id
        HAVING ABS(p.current_balance - (COALESCE(SUM(le.debit_amount - le.credit_amount), 0) + p.opening_balance)) > 0.01
    ) c;


    -- 3. CHECK NEGATIVE STOCK (MEDIUM: Business Process Issue)
    SELECT json_agg(t) INTO v_stock_data
    FROM (
        SELECT f.name, i.quantity
        FROM inventory i
        JOIN fuel_types f ON i.fuel_type_id = f.id
        WHERE i.quantity < 0
    ) t;
    
    SELECT COUNT(*) INTO v_negative_stock_count FROM inventory WHERE quantity < 0;


    -- 4. RETURN DIAGNOSTIC REPORT
    RETURN json_build_object(
        'status', CASE 
            WHEN v_imbalanced_count > 0 THEN 'CRITICAL_FAILURE'
            WHEN v_sync_error_count > 0 THEN 'INTEGRITY_WARNING'
            WHEN v_negative_stock_count > 0 THEN 'PROCESS_WARNING'
            ELSE 'HEALTHY' 
        END,
        'checked_at', now(),
        'summary', json_build_object(
            'imbalanced_vouchers_count', v_imbalanced_count,
            'party_sync_errors_count', v_sync_error_count,
            'negative_stock_items_count', v_negative_stock_count
        ),
        'details', json_build_object(
            'imbalanced_vouchers', COALESCE(v_imbalanced_data, '[]'::json),
            'party_sync_errors', COALESCE(v_sync_data, '[]'::json),
            'negative_stock_items', COALESCE(v_stock_data, '[]'::json)
        )
    );
END;
$$ LANGUAGE plpgsql;

COMMIT;

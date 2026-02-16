-- ============================================================================
-- FIX STATEMENT & LEDGER ORDERING - Sequential Audit Flow
-- ============================================================================
-- Ensures all statements and ledgers follow a strict sequential order:
-- 1. Posting Date (The accounting date)
-- 2. Created At (The real-world entry time)
-- 3. Voucher No (The sequence number)
-- This removes the "jumping" behavior where payments appear before/after bills
-- on the same day based on arbitrary type priorities.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION get_party_statement(
    p_party_id UUID, 
    p_start_date DATE DEFAULT '2000-01-01', 
    p_end_date DATE DEFAULT '2099-12-31'
)
RETURNS TABLE (
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
LANGUAGE plpgsql STABLE AS $$
DECLARE 
    v_opening_balance NUMERIC(15, 2) := 0;
BEGIN
    -- 1. Calculate Opening Balance
    SELECT 
        COALESCE(p.opening_balance, 0::NUMERIC) + 
        COALESCE((
            SELECT SUM(COALESCE(le_op.debit_amount, 0) - COALESCE(le_op.credit_amount, 0))
            FROM ledger_entries le_op
            WHERE le_op.party_id = p_party_id 
              AND COALESCE(le_op.is_reversed, false) = false 
              AND le_op.posting_date < p_start_date
        ), 0::NUMERIC)
    INTO v_opening_balance 
    FROM parties p 
    WHERE p.id = p_party_id;

    v_opening_balance := ROUND(COALESCE(v_opening_balance, 0)::NUMERIC, 2);

    -- 2. Return Opening Row
    RETURN QUERY 
    SELECT 
        (p_start_date - INTERVAL '1 day')::DATE as posting_date,
        'OPEN'::TEXT as voucher_no, 
        'Opening Balance'::TEXT as particulars, 
        'B/F'::TEXT as details, 
        '--'::TEXT as contra_mode, 
        NULL::NUMERIC as qty, 
        NULL::NUMERIC as rate,
        CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0::NUMERIC END as debit,
        CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0::NUMERIC END as credit, 
        v_opening_balance as running_balance, 
        NULL::TEXT as fuel_name,
        false as is_reversed_entry;

    -- 3. Return Transactions with SEQUENTIAL SORTING
    RETURN QUERY
    WITH aux_info AS (
        SELECT s.voucher_no as v_ref, s.quantity::NUMERIC(15, 3) as qty_val, s.rate_per_unit::NUMERIC(15, 2) as rate_val, ft.name as f_name 
        FROM sales s JOIN fuel_types ft ON s.fuel_type_id = ft.id
        UNION ALL
        SELECT pu.voucher_no as v_ref, pu.quantity::NUMERIC(15, 3) as qty_val, pu.rate_per_unit::NUMERIC(15, 2) as rate_val, ft.name as f_name 
        FROM purchases pu JOIN fuel_types ft ON pu.fuel_type_id = ft.id
    ),
    entries AS (
        SELECT 
            le.posting_date,
            le.voucher_no,
            COALESCE(le.narration, '') as particulars,
            le.voucher_type::TEXT as details,
            (SELECT COALESCE(pr.name, acc.name, 'Multiple') FROM ledger_entries le2 LEFT JOIN parties pr ON le2.party_id = pr.id LEFT JOIN accounts acc ON le2.account_id = acc.id WHERE le2.voucher_no = le.voucher_no AND le2.id != le.id AND COALESCE(le2.is_reversed, false) = false LIMIT 1) as contra_mode,
            ai.qty_val as qty,
            ai.rate_val as rate,
            ROUND(COALESCE(le.debit_amount, 0)::NUMERIC, 2) as debit_amount,
            ROUND(COALESCE(le.credit_amount, 0)::NUMERIC, 2) as credit_amount,
            
            -- Running Balance with SEQUENTIAL Logic
            ROUND(
                SUM(COALESCE(le.debit_amount, 0) - COALESCE(le.credit_amount, 0)) 
                OVER (
                    ORDER BY 
                        le.posting_date,
                        le.created_at, -- Real order of entry
                        le.voucher_no  -- Secondary tie-breaker
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                ) + v_opening_balance
            , 2) as running_balance,
            ai.f_name as fuel_name,
            COALESCE(le.is_reversed, false) as is_reversed_entry,
            le.created_at -- Added for final sorting
        FROM ledger_entries le 
        LEFT JOIN aux_info ai ON le.voucher_no = ai.v_ref
        WHERE le.party_id = p_party_id 
          AND le.posting_date BETWEEN p_start_date AND p_end_date
    )
    SELECT posting_date, voucher_no, particulars, details, contra_mode, qty, rate, debit_amount as debit, credit_amount as credit, running_balance, fuel_name, is_reversed_entry 
    FROM entries
    ORDER BY posting_date, created_at, voucher_no; -- Final guaranteed order
END; 
$$;

COMMIT;

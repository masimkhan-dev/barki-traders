-- Phase 21: FIX AMBIGUITY & DIALOG WARNINGS
-- ---------------------------------------------------------------------------
BEGIN;

-- 1. DROP old function to avoid parameter/naming conflicts (42P13 error fix)
DROP FUNCTION IF EXISTS get_party_statement(UUID, DATE, DATE);

-- 2. CREATE Fixed Function with Explicit Qualifications (Reduces Ambiguity)
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
    fuel_name TEXT
) 
LANGUAGE plpgsql STABLE AS $$
DECLARE 
    v_opening_balance NUMERIC;
BEGIN
    -- Calculate Opening Balance (using explicit aliases to avoid column/variable collision)
    SELECT 
        COALESCE(p.opening_balance, 0) + 
        COALESCE((
            SELECT SUM(le_op.debit_amount - le_op.credit_amount)
            FROM ledger_entries le_op
            WHERE le_op.party_id = p_party_id 
              AND le_op.is_reversed = false 
              AND le_op.posting_date < p_start_date
        ), 0) INTO v_opening_balance 
    FROM parties p WHERE p.id = p_party_id;

    RETURN QUERY 
    WITH aux_info AS (
        -- Explicitly qualified columns for safety
        SELECT s.voucher_no as v_ref, s.quantity as qty_val, s.rate_per_unit as rate_val, ft.name as f_name 
        FROM sales s JOIN fuel_types ft ON s.fuel_type_id = ft.id
        UNION ALL
        SELECT pu.voucher_no as v_ref, pu.quantity as qty_val, pu.rate_per_unit as rate_val, ft.name as f_name 
        FROM purchases pu JOIN fuel_types ft ON pu.fuel_type_id = ft.id
    ),
    entries AS (
        SELECT 
            le.posting_date as p_dt,
            le.voucher_no as v_num,
            le.narration as p_nar,
            le.voucher_type::TEXT as v_ty,
            'Multiple'::TEXT as c_md,
            ai.qty_val,
            ai.rate_val,
            le.debit_amount as d_am,
            le.credit_amount as c_am,
            SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at, le.id) + v_opening_balance as r_bal,
            ai.f_name
        FROM ledger_entries le 
        LEFT JOIN aux_info ai ON le.voucher_no = ai.v_ref
        WHERE le.party_id = p_party_id 
          AND le.is_reversed = false 
          AND le.posting_date BETWEEN p_start_date AND p_end_date
    )
    -- Unified Result Set
    SELECT (p_start_date - INTERVAL '1 day')::DATE, 'OPEN'::TEXT, 'Opening Balance'::TEXT, 'B/F'::TEXT, '--'::TEXT, NULL::NUMERIC, NULL::NUMERIC,
           CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0 END,
           CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0 END, 
           v_opening_balance, NULL::TEXT
    UNION ALL 
    SELECT * FROM entries 
    ORDER BY 1 ASC, 10 ASC; -- Sort by Posting Date and Running Balance
END; $$;

COMMIT;

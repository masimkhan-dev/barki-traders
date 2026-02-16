-- Phase 18: FIX AMBIGUOUS COLUMN REFERENCE
-- -----------------------------------------------------------------
-- Fixes the "voucher_no is ambiguous" error in get_party_statement
-- by adding explicit table aliases in subqueries.

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
    running_balance NUMERIC
) LANGUAGE plpgsql AS $$
DECLARE
    v_opening_balance NUMERIC;
BEGIN
    -- 1. Calculate Opening Balance
    SELECT 
        COALESCE(p.opening_balance, 0) + 
        COALESCE((
            SELECT SUM(le_op.debit_amount - le_op.credit_amount)
            FROM ledger_entries le_op
            WHERE le_op.party_id = p_party_id 
              AND le_op.is_reversed = false
              AND le_op.voucher_no NOT LIKE 'REV-%'
              AND le_op.posting_date < p_start_date
        ), 0) INTO v_opening_balance 
    FROM parties p WHERE p.id = p_party_id;

    -- 2. Entry 0: Opening Balance Row
    RETURN QUERY 
    SELECT 
        (p_start_date - INTERVAL '1 day')::DATE,
        'OPEN'::TEXT,
        'Opening Balance'::TEXT,
        'Brought Forward'::TEXT,
        '--'::TEXT,
        NULL::NUMERIC,
        NULL::NUMERIC,
        CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0 END,
        CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0 END,
        v_opening_balance;

    -- 3. Subsequent entries with running balance
    RETURN QUERY
    WITH entries AS (
        SELECT 
            le.posting_date,
            le.voucher_no,
            le.narration as particulars,
            le.voucher_type::TEXT as details,
            (
                SELECT COALESCE(pr.name, acc.name)
                FROM ledger_entries le2
                LEFT JOIN parties pr ON le2.party_id = pr.id
                LEFT JOIN accounts acc ON le2.account_id = acc.id
                WHERE le2.voucher_no = le.voucher_no 
                AND le2.id != le.id
                LIMIT 1
            ) as contra_mode,
            (SELECT s.quantity FROM sales s WHERE s.voucher_no = le.voucher_no LIMIT 1) as qty,
            (SELECT s.rate_per_unit FROM sales s WHERE s.voucher_no = le.voucher_no LIMIT 1) as rate,
            le.debit_amount,
            le.credit_amount,
            SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at) + v_opening_balance as running_balance
        FROM ledger_entries le
        WHERE le.party_id = p_party_id
          AND le.is_reversed = false
          AND le.voucher_no NOT LIKE 'REV-%'
          AND le.posting_date BETWEEN p_start_date AND p_end_date
        ORDER BY le.posting_date, le.created_at
    )
    SELECT * FROM entries;
END;
$$;

COMMIT;
NOTIFY pgrst, 'reload config';

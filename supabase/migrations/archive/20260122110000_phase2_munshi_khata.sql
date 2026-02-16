-- PHASE 2: MUNSHI STATEMENT LOGIC (KHATA) - FINAL POLISHED
-- -----------------------------------------------------
-- This migration refactors the 'get_party_statement' RPC to ensure it strictly obeys 
-- Munshi principles following the Phase 1 hardening.
-- 1. Filters out all internal GL accounts (achieved via party_id=NULL in Phase 1).
-- 2. Groups by Voucher Number to ensure 1 row per transaction.
-- 3. shows "Clean" particulars with Robust Logic (Mixed Type detection).
-- 4. Computes Running Balance efficiently with Rounding and Noise Filtering.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_party_statement(p_party_id UUID, p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    posting_date DATE, 
    voucher_no TEXT, 
    particulars TEXT, 
    debit NUMERIC, 
    credit NUMERIC, 
    running_balance NUMERIC
) AS $$
DECLARE 
    v_opening_balance NUMERIC := 0;
BEGIN
    -- 1. CALCULATE OPENING BALANCE
    -- Sum of (Debit - Credit) for all entries BEFORE the start date
    -- PLUS the static opening_balance from the party record
    SELECT 
        COALESCE(p.opening_balance, 0) + 
        COALESCE((
            SELECT SUM(le.debit_amount - le.credit_amount)
            FROM ledger_entries le
            WHERE le.party_id = p_party_id 
              AND le.posting_date < p_start_date
        ), 0)
    INTO v_opening_balance
    FROM parties p
    WHERE p.id = p_party_id;

    -- 2. RETURN OPENING ROW (Standard Munshi Practice, Rounded)
    RETURN QUERY SELECT 
        (p_start_date - INTERVAL '1 day')::DATE as posting_date,
        'OPENING'::TEXT as voucher_no,
        'Opening Balance B/F'::TEXT as particulars,
        ROUND(CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0.0 END, 2) as debit,
        ROUND(CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0.0 END, 2) as credit,
        ROUND(v_opening_balance, 2) as running_balance;

    -- 3. RETURN TRANSACTION ROWS
    RETURN QUERY 
    WITH raw_tx AS (
        SELECT 
            le.posting_date,
            le.voucher_no,
            le.voucher_type,
            COALESCE(le.narration, '') as narration,
            le.debit_amount,
            le.credit_amount,
            le.created_at
        FROM ledger_entries le
        WHERE le.party_id = p_party_id 
          AND le.posting_date BETWEEN p_start_date AND p_end_date
          -- Filter Noise: Ignore Zero-Amount entries (e.g. system adjustments)
          AND (le.debit_amount != 0 OR le.credit_amount != 0)
    ),
    grouped_tx AS (
        SELECT 
            r.posting_date,
            r.voucher_no,
            -- Robust Narration: Combine all distinct notes to avoid losing details
            string_agg(DISTINCT r.narration, ' | ') as narration,
            
            -- Robust Type Logic (Detect Mixed/Adjustment)
            CASE 
                WHEN COUNT(DISTINCT r.voucher_type) > 1 THEN 'Adjustment/Mixed'
                WHEN MAX(r.voucher_type) = 'sale' THEN 'Fuel Sale'
                WHEN MAX(r.voucher_type) = 'purchase' THEN 'Fuel Purchase'
                WHEN MAX(r.voucher_type) = 'payment' THEN 
                    -- Dynamic Direction Label for Payments
                    CASE 
                        WHEN SUM(r.debit_amount) > SUM(r.credit_amount) THEN 'Payment (Dr)'
                        ELSE 'Payment (Cr)'
                    END
                ELSE MAX(r.voucher_type) -- Fallback
            END as type_label,
            
            SUM(r.debit_amount) as total_debit,
            SUM(r.credit_amount) as total_credit,
            MIN(r.created_at) as sort_time
        FROM raw_tx r
        GROUP BY r.posting_date, r.voucher_no
    )
    SELECT 
        g.posting_date,
        g.voucher_no,
        -- Combine Type + Narration for a rich Munshi description
        (g.type_label || ' - ' || g.narration)::TEXT as particulars,
        ROUND(g.total_debit, 2) as debit,
        ROUND(g.total_credit, 2) as credit,
        -- Running Balance: Opening + Cumulative Sum over window
        ROUND(
            (SUM(g.total_debit - g.total_credit) OVER (ORDER BY g.posting_date, g.sort_time, g.voucher_no) + v_opening_balance), 
            2
        )::NUMERIC
    FROM grouped_tx g
    ORDER BY g.posting_date, g.sort_time, g.voucher_no;

END;
$$ LANGUAGE plpgsql;

COMMIT;

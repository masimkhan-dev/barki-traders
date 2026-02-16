-- Phase 16: HIDE REVERSED ENTRIES FROM STATEMENTS
-- -----------------------------------------------------------------
-- Updates the party statement RPC to exclude entries that have been reversed.
-- This ensures the "Clean" view for the owner/munshi.

BEGIN;

CREATE OR REPLACE FUNCTION get_party_statement(p_party_id UUID)
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
    is_reversed_entry BOOLEAN -- Added for UI styling if needed
) LANGUAGE plpgsql AS $$
DECLARE
    v_opening_balance NUMERIC;
BEGIN
    -- Get the party's opening balance from the parties table
    SELECT COALESCE(opening_balance, 0) INTO v_opening_balance FROM parties WHERE id = p_party_id;

    -- Entry 0: Opening Balance
    RETURN QUERY 
    SELECT 
        COALESCE((SELECT MIN(posting_date) - INTERVAL '1 day' FROM ledger_entries WHERE party_id = p_party_id)::DATE, CURRENT_DATE),
        'OPEN'::TEXT,
        'Opening Balance'::TEXT,
        'Brought Forward'::TEXT,
        '--'::TEXT,
        NULL::NUMERIC,
        NULL::NUMERIC,
        CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0 END,
        CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0 END,
        v_opening_balance,
        false;

    -- Subsequent entries with running balance
    RETURN QUERY
    WITH entries AS (
        SELECT 
            le.posting_date,
            le.voucher_no,
            le.narration as particulars,
            le.voucher_type::TEXT as details,
            (
                SELECT COALESCE(p.name, a.name)
                FROM ledger_entries le2
                LEFT JOIN parties p ON le2.party_id = p.id
                LEFT JOIN accounts a ON le2.account_id = a.id
                WHERE le2.voucher_no = le.voucher_no 
                AND le2.id != le.id
                LIMIT 1
            ) as contra_mode,
            NULL::NUMERIC as qty, 
            NULL::NUMERIC as rate,
            le.debit_amount,
            le.credit_amount,
            SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at) + v_opening_balance as running_balance,
            le.is_reversed
        FROM ledger_entries le
        WHERE le.party_id = p_party_id
          AND le.is_reversed = false -- MASK REVERSED ENTRIES
          AND le.voucher_no NOT LIKE 'REV-%' -- MASK REVERSAL ENTRIES
        ORDER BY le.posting_date, le.created_at
    )
    SELECT * FROM entries;
END;
$$;

COMMIT;

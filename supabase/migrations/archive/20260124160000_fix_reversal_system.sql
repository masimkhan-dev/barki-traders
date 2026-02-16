-- Phase 17: EMERGENCY REPAIR - REVERSAL SYSTEM & STATEMENT SIGNATURE
-- -----------------------------------------------------------------
-- 1. Fixes signature mismatch in get_party_statement (restores 3 params).
-- 2. Fixes broken column names in reverse_transaction RPC (party_id, method).
-- 3. Implements standard 10-column return for Ledger UI compatibility.
-- 4. Ensures audit-safe masking of reversed transactions.

BEGIN;

--------------------------------------------------------------------------------
-- 1. DROP EXISTING TO CLEAR OVERLOADS
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_party_statement(UUID);
DROP FUNCTION IF EXISTS public.get_party_statement(UUID, DATE, DATE);
DROP FUNCTION IF EXISTS public.reverse_transaction(TEXT, TEXT);

--------------------------------------------------------------------------------
-- 2. REPAIR REVERSE_TRANSACTION RPC
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reverse_transaction(
    p_voucher_no TEXT,
    p_reason TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_voucher_type TEXT;
    v_new_voucher_no TEXT;
    v_result json;
    v_record_found BOOLEAN := false;
BEGIN
    -- Validation
    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        RAISE EXCEPTION 'Reversal reason is mandatory';
    END IF;

    IF p_voucher_no LIKE 'REV-%' THEN
        RAISE EXCEPTION 'Cannot reverse a reversal transaction';
    END IF;

    -- 1. Check if already reversed
    IF EXISTS (SELECT 1 FROM ledger_entries WHERE voucher_no = p_voucher_no AND is_reversed = true) THEN
        RAISE EXCEPTION 'This transaction is already reversed';
    END IF;

    v_new_voucher_no := 'REV-' || p_voucher_no;

    -- 2. Handle SALES Reversal (Unified party_id)
    IF EXISTS (SELECT 1 FROM sales WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO sales (voucher_no, sale_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, is_credit, notes, created_by)
        SELECT v_new_voucher_no, CURRENT_DATE, party_id, fuel_type_id, -quantity, rate_per_unit, -total_amount, is_credit, 'Reversal: ' || p_reason, auth.uid()
        FROM sales WHERE voucher_no = p_voucher_no;
        
        UPDATE sales SET is_reversed = true WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- 3. Handle PURCHASES Reversal (Unified party_id)
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM purchases WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO purchases (voucher_no, purchase_date, party_id, fuel_type_id, quantity, rate_per_unit, total_amount, notes, created_by)
        SELECT v_new_voucher_no, CURRENT_DATE, party_id, fuel_type_id, -quantity, rate_per_unit, -total_amount, 'Reversal: ' || p_reason, auth.uid()
        FROM purchases WHERE voucher_no = p_voucher_no;
        
        UPDATE purchases SET is_reversed = true WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- 4. Handle PAYMENTS/RECEIPTS Reversal (Unified party_id, correct method column)
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM payments WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO payments (voucher_no, payment_type, payment_date, party_id, amount, method, notes, created_by)
        SELECT v_new_voucher_no, payment_type, CURRENT_DATE, party_id, -amount, method, 'Reversal: ' || p_reason, auth.uid()
        FROM payments WHERE voucher_no = p_voucher_no;
        
        UPDATE payments SET is_reversed = true WHERE voucher_no = p_voucher_no;
        v_record_found := true;
    END IF;

    -- 5. Handle Generic LEDGER entries (e.g. Expenses or Manual Vouchers)
    IF NOT v_record_found AND EXISTS (SELECT 1 FROM ledger_entries WHERE voucher_no = p_voucher_no) THEN
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        SELECT v_new_voucher_no, voucher_type, CURRENT_DATE, account_id, party_id, credit_amount, debit_amount, 'Reversal: ' || p_reason, auth.uid()
        FROM ledger_entries WHERE voucher_no = p_voucher_no AND is_reversed = false;
        
        v_record_found := true;
    END IF;

    IF NOT v_record_found THEN
        RAISE EXCEPTION 'Voucher numbered % not found', p_voucher_no;
    END IF;

    -- Final Mark on Ledger
    UPDATE ledger_entries 
    SET is_reversed = true, narration = COALESCE(narration, '') || ' (REVERSED: ' || p_reason || ')'
    WHERE voucher_no = p_voucher_no;

    SELECT json_build_object('success', true, 'reversal_voucher', v_new_voucher_no) INTO v_result;
    RETURN v_result;
END;
$$;

--------------------------------------------------------------------------------
-- 3. REPAIR GET_PARTY_STATEMENT (3 PARAMS, 10 COLUMNS)
--------------------------------------------------------------------------------
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
    -- 1. Calculate Opening Balance (Party opening + ledger before start date, excluding reversed)
    SELECT 
        COALESCE(p.opening_balance, 0) + 
        COALESCE((
            SELECT SUM(le.debit_amount - le.credit_amount)
            FROM ledger_entries le
            WHERE le.party_id = p_party_id 
              AND le.is_reversed = false
              AND le.voucher_no NOT LIKE 'REV-%'
              AND le.posting_date < p_start_date
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

    -- 3. Subsequent entries with running balance (Masking reversals)
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
            NULLIF((SELECT quantity FROM sales WHERE voucher_no = le.voucher_no LIMIT 1), 0) as qty,
            NULLIF((SELECT rate_per_unit FROM sales WHERE voucher_no = le.voucher_no LIMIT 1), 0) as rate,
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

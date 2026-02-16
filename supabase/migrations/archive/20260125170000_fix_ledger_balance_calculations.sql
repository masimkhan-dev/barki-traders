-- ============================================================================
-- LEDGER BALANCE FIX - Corrected for Your Schema
-- ============================================================================
-- This migration fixes ledger balance calculation issues
-- Verified against your actual database schema
-- ============================================================================

BEGIN;

-- 1. ENFORCE NON-NULL CONSTRAINT on ledger_entries
-- ===========================================================================
UPDATE ledger_entries 
SET debit_amount = 0 
WHERE debit_amount IS NULL;

UPDATE ledger_entries 
SET credit_amount = 0 
WHERE credit_amount IS NULL;

ALTER TABLE ledger_entries 
ALTER COLUMN debit_amount SET DEFAULT 0,
ALTER COLUMN debit_amount SET NOT NULL;

ALTER TABLE ledger_entries 
ALTER COLUMN credit_amount SET DEFAULT 0,
ALTER COLUMN credit_amount SET NOT NULL;

-- Drop and recreate constraint (idempotent)
ALTER TABLE ledger_entries 
DROP CONSTRAINT IF EXISTS chk_ledger_amounts_not_null;

ALTER TABLE ledger_entries 
ADD CONSTRAINT chk_ledger_amounts_not_null 
CHECK (debit_amount IS NOT NULL AND credit_amount IS NOT NULL);


-- 2. RECREATE get_party_statement with BANK-GRADE precision
-- ===========================================================================
DROP FUNCTION IF EXISTS get_party_statement(UUID, DATE, DATE);

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
    v_opening_balance NUMERIC(15, 2) := 0;
BEGIN
    -- Calculate Opening Balance with COALESCE safety
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

    -- Return Opening Balance Row
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
        NULL::TEXT as fuel_name;

    -- Return Transaction Entries with FIXED Running Balance Logic
    RETURN QUERY
    WITH aux_info AS (
        SELECT 
            s.voucher_no as v_ref, 
            s.quantity::NUMERIC(15, 3) as qty_val, 
            s.rate_per_unit::NUMERIC(15, 2) as rate_val, 
            ft.name as f_name 
        FROM sales s 
        JOIN fuel_types ft ON s.fuel_type_id = ft.id
        UNION ALL
        SELECT 
            pu.voucher_no as v_ref, 
            pu.quantity::NUMERIC(15, 3) as qty_val, 
            pu.rate_per_unit::NUMERIC(15, 2) as rate_val, 
            ft.name as f_name 
        FROM purchases pu 
        JOIN fuel_types ft ON pu.fuel_type_id = ft.id
    ),
    entries AS (
        SELECT 
            le.posting_date,
            le.voucher_no,
            COALESCE(le.narration, '') as particulars,
            le.voucher_type::TEXT as details,
            (
                SELECT COALESCE(pr.name, acc.name, 'Multiple')
                FROM ledger_entries le2
                LEFT JOIN parties pr ON le2.party_id = pr.id
                LEFT JOIN accounts acc ON le2.account_id = acc.id
                WHERE le2.voucher_no = le.voucher_no 
                  AND le2.id != le.id
                  AND COALESCE(le2.is_reversed, false) = false
                LIMIT 1
            ) as contra_mode,
            ai.qty_val as qty,
            ai.rate_val as rate,
            ROUND(COALESCE(le.debit_amount, 0)::NUMERIC, 2) as debit_amount,
            ROUND(COALESCE(le.credit_amount, 0)::NUMERIC, 2) as credit_amount,
            -- CRITICAL FIX: Proper ordering and precision
            ROUND(
                SUM(COALESCE(le.debit_amount, 0) - COALESCE(le.credit_amount, 0)) 
                OVER (
                    ORDER BY le.posting_date, le.voucher_no, le.created_at, le.id
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                ) + v_opening_balance
            , 2) as running_balance,
            ai.f_name as fuel_name
        FROM ledger_entries le 
        LEFT JOIN aux_info ai ON le.voucher_no = ai.v_ref
        WHERE le.party_id = p_party_id 
          AND COALESCE(le.is_reversed, false) = false
          AND le.posting_date BETWEEN p_start_date AND p_end_date
        ORDER BY le.posting_date, le.voucher_no, le.created_at, le.id
    )
    SELECT * FROM entries;
END; 
$$;

-- 3. ADD INDEX for deterministic voucher ordering
-- ===========================================================================
CREATE INDEX IF NOT EXISTS idx_ledger_entries_statement_order
ON ledger_entries (party_id, posting_date, voucher_no, created_at, id)
WHERE COALESCE(is_reversed, false) = false;

-- 4. CREATE AUDIT FUNCTION (adapted to your schema)
-- ===========================================================================
DROP FUNCTION IF EXISTS audit_ledger_integrity();

CREATE OR REPLACE FUNCTION audit_ledger_integrity()
RETURNS TABLE (
    issue_type TEXT,
    voucher_no TEXT,
    party_name TEXT,
    description TEXT,
    severity TEXT
)
LANGUAGE plpgsql AS $$
BEGIN
    -- Check 1: NULL amounts
    RETURN QUERY
    SELECT 
        'NULL_AMOUNTS'::TEXT,
        le.voucher_no,
        COALESCE(p.name, 'Unknown'),
        'Ledger entry has NULL debit or credit amount'::TEXT,
        'CRITICAL'::TEXT
    FROM ledger_entries le
    LEFT JOIN parties p ON le.party_id = p.id
    WHERE le.debit_amount IS NULL OR le.credit_amount IS NULL;

    -- Check 2: Unbalanced vouchers
    RETURN QUERY
    SELECT 
        'UNBALANCED_VOUCHER'::TEXT,
        le.voucher_no,
        'Multiple Parties'::TEXT,
        'Total debits (' || SUM(le.debit_amount)::TEXT || ') != Total credits (' || SUM(le.credit_amount)::TEXT || ')'::TEXT,
        'HIGH'::TEXT
    FROM ledger_entries le
    WHERE COALESCE(le.is_reversed, false) = false
    GROUP BY le.voucher_no
    HAVING ROUND(SUM(le.debit_amount)::NUMERIC, 2) != ROUND(SUM(le.credit_amount)::NUMERIC, 2);

    RETURN;
END;
$$;

-- 5. CREATE HELPER FUNCTION to recalculate party balances
-- ===========================================================================
DROP FUNCTION IF EXISTS recalculate_party_balance(UUID);

CREATE OR REPLACE FUNCTION recalculate_party_balance(p_party_id UUID)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC(15, 2);
BEGIN
    SELECT 
        COALESCE(p.opening_balance, 0) + 
        COALESCE(SUM(COALESCE(le.debit_amount, 0) - COALESCE(le.credit_amount, 0)), 0)
    INTO v_balance
    FROM parties p
    LEFT JOIN ledger_entries le ON le.party_id = p.id 
        AND COALESCE(le.is_reversed, false) = false
    WHERE p.id = p_party_id
    GROUP BY p.opening_balance;

    RETURN ROUND(COALESCE(v_balance, 0), 2);
END;
$$;

COMMIT;

NOTIFY pgrst, 'reload config';

-- ============================================================================
-- VALIDATION QUERIES (Run these after migration)
-- ============================================================================

-- 1. Check for issues
SELECT * FROM audit_ledger_integrity();

-- 2. Check party balances (Top 20)
SELECT 
    p.name as party_name,
    p.type as party_type,  -- Corrected: 'type' not 'party_type'
    recalculate_party_balance(p.id) as balance,
    CASE 
        WHEN recalculate_party_balance(p.id) >= 0 THEN 'Dr (Receivable)'
        ELSE 'Cr (Payable)'
    END as balance_type,
    ABS(recalculate_party_balance(p.id)) as amount
FROM parties p
WHERE p.is_active = true
ORDER BY ABS(recalculate_party_balance(p.id)) DESC
LIMIT 20;

-- 3. Statistics
SELECT 
    'Total Active Entries' as metric,
    COUNT(*)::TEXT as value
FROM ledger_entries
WHERE COALESCE(is_reversed, false) = false
UNION ALL
SELECT 
    'Entries with NULL amounts (should be 0)',
    COUNT(*)::TEXT
FROM ledger_entries
WHERE debit_amount IS NULL OR credit_amount IS NULL
UNION ALL
SELECT 
    'Total Suppliers Balance (Cr)',
    COALESCE(ABS(SUM(recalculate_party_balance(p.id)))::TEXT, '0')
FROM parties p
WHERE p.type IN ('supplier', 'both') AND recalculate_party_balance(p.id) < 0
UNION ALL
SELECT 
    'Total Customers Balance (Dr)',
    COALESCE(SUM(recalculate_party_balance(p.id))::TEXT, '0')
FROM parties p
WHERE p.type IN ('customer', 'both') AND recalculate_party_balance(p.id) > 0;

-- ============================================================================
-- SUCCESS!
-- To test a specific party:
-- SELECT * FROM get_party_statement('party-uuid', '2026-01-25', '2026-01-25');
-- ============================================================================

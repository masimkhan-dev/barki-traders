-- PHASE 23: AUDIT MASTER REPAIR (MASTER STROKE)
-- MISSION: FIX REPORTING DISCREPANCIES, AUTOMATE VOUCHERS, AND LOCK DOWN THE LEDGER
-- ---------------------------------------------------------------------------

BEGIN;

-- 1. AUTOMATIC VOUCHER GENERATION TRIGGERS
-- ---------------------------------------------------------------------------
-- This ensures that even if the frontend sends a voucher, the DB enforces the strict sequence-based format.
CREATE OR REPLACE FUNCTION public.enforce_voucher_sequence()
RETURNS TRIGGER AS $$
DECLARE
    v_prefix TEXT;
    v_date DATE;
BEGIN
    -- Get table-specific prefix and date safely
    IF TG_TABLE_NAME = 'sales' THEN 
        v_prefix := 'SAL';
        v_date := NEW.sale_date;
    ELSIF TG_TABLE_NAME = 'purchases' THEN 
        v_prefix := 'PUR';
        v_date := NEW.purchase_date;
    ELSIF TG_TABLE_NAME = 'payments' THEN 
        v_date := NEW.payment_date;
        IF NEW.payment_type = 'receipt' THEN v_prefix := 'RCT'; ELSE v_prefix := 'PAY'; END IF;
    ELSE 
        v_prefix := 'GEN';
        v_date := CURRENT_DATE;
    END IF;

    -- Always override to ensure sequence integrity and no duplicates
    NEW.voucher_no := get_next_voucher_no(v_prefix, COALESCE(v_date, CURRENT_DATE));
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_enforce_sales_voucher ON sales;
CREATE TRIGGER trg_enforce_sales_voucher BEFORE INSERT ON sales FOR EACH ROW EXECUTE FUNCTION enforce_voucher_sequence();

DROP TRIGGER IF EXISTS trg_enforce_purchases_voucher ON purchases;
CREATE TRIGGER trg_enforce_purchases_voucher BEFORE INSERT ON purchases FOR EACH ROW EXECUTE FUNCTION enforce_voucher_sequence();

DROP TRIGGER IF EXISTS trg_enforce_payments_voucher ON payments;
CREATE TRIGGER trg_enforce_payments_voucher BEFORE INSERT ON payments FOR EACH ROW EXECUTE FUNCTION enforce_voucher_sequence();


-- 2. FIX TRIAL BALANCE (The common 400 error)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS get_trial_balance(DATE, DATE);
CREATE OR REPLACE FUNCTION get_trial_balance(p_start_date DATE DEFAULT '2000-01-01', p_end_date DATE DEFAULT '2099-12-31')
RETURNS TABLE (
    account_id UUID,
    account_code TEXT,
    account_name TEXT,
    account_type TEXT,
    opening_debit NUMERIC,
    opening_credit NUMERIC,
    period_debit NUMERIC,
    period_credit NUMERIC,
    closing_balance NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        a.id,
        a.code,
        a.name,
        a.account_type::TEXT, -- Fix: use correct column name
        -- Opening (Before start date)
        COALESCE(SUM(CASE WHEN le.posting_date < p_start_date THEN le.debit_amount ELSE 0 END), 0) as op_dr,
        COALESCE(SUM(CASE WHEN le.posting_date < p_start_date THEN le.credit_amount ELSE 0 END), 0) as op_cr,
        -- Period
        COALESCE(SUM(CASE WHEN le.posting_date BETWEEN p_start_date AND p_end_date THEN le.debit_amount ELSE 0 END), 0) as p_dr,
        COALESCE(SUM(CASE WHEN le.posting_date BETWEEN p_start_date AND p_end_date THEN le.credit_amount ELSE 0 END), 0) as p_cr,
        -- Closing
        COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as final_bal
    FROM accounts a
    LEFT JOIN ledger_entries le ON le.account_id = a.id AND le.posting_date <= p_end_date AND le.is_reversed = false
    GROUP BY a.id, a.code, a.name, a.account_type
    ORDER BY a.code;
END;
$$ LANGUAGE plpgsql STABLE;


-- 3. FIX PARTY STATEMENT (Ambiguity & Ordering)
-- ---------------------------------------------------------------------------
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
) AS $$
DECLARE 
    v_opening_balance NUMERIC;
BEGIN
    -- Comprehensive Opening Balance
    SELECT 
        COALESCE(p.opening_balance, 0) + 
        COALESCE((
            SELECT SUM(le_op.debit_amount - le_op.credit_amount)
            FROM ledger_entries le_op
            WHERE le_op.party_id = p_party_id 
              AND le_op.is_reversed = false 
              AND le_op.posting_date < p_start_date
              -- Exclude 'opening' voucher types if they are already accounted for in parties.opening_balance
              -- but usually, they are mirrored. We must ensure no double counting.
        ), 0) INTO v_opening_balance 
    FROM parties p WHERE p.id = p_party_id;

    RETURN QUERY 
    WITH entries AS (
        SELECT 
            le.posting_date as p_dt,
            le.voucher_no as v_num,
            le.narration as p_nar,
            le.voucher_type::TEXT as v_ty,
            'Ledger'::TEXT as c_md,
            NULL::NUMERIC as q,
            NULL::NUMERIC as r,
            le.debit_amount as d_am,
            le.credit_amount as c_am,
            SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at, le.id) + v_opening_balance as r_bal,
            NULL::TEXT as f_n
        FROM ledger_entries le 
        WHERE le.party_id = p_party_id 
          AND le.is_reversed = false 
          AND le.posting_date BETWEEN p_start_date AND p_end_date
    )
    -- Include Opening Row
    SELECT (p_start_date - INTERVAL '1 day')::DATE, 'OPEN'::TEXT, 'Opening Balance'::TEXT, 'B/F'::TEXT, '--'::TEXT, NULL::NUMERIC, NULL::NUMERIC,
           CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0 END,
           CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0 END, 
           v_opening_balance, NULL::TEXT
    UNION ALL 
    SELECT * FROM entries 
    ORDER BY 1 ASC, 10 ASC;
END; $$ LANGUAGE plpgsql STABLE;


-- 4. FINAL PERMISSIONS & SECURITY
-- ---------------------------------------------------------------------------
-- Ensure execute permissions on all RPCs for authenticated users
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- Revoke dangerous direct mutations again just to be sure
REVOKE UPDATE, DELETE ON ledger_entries FROM authenticated;
REVOKE UPDATE, DELETE ON sales FROM authenticated;
REVOKE UPDATE, DELETE ON purchases FROM authenticated;
REVOKE UPDATE, DELETE ON payments FROM authenticated;

COMMIT;

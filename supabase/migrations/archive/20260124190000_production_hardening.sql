-- Phase 20: PRODUCTION HARDENING & SECURITY (RLS, OPTIMIZATION, RECONCILIATION)
-- ---------------------------------------------------------------------------
BEGIN;

-- 1. RECONCILIATION SYSTEM
ALTER TABLE public.ledger_entries ADD COLUMN reconciliation_status BOOLEAN DEFAULT false;
ALTER TABLE public.ledger_entries ADD COLUMN reconciled_at TIMESTAMPTZ;

-- 2. FISCAL PERIODS (Yearly/Monthly Closing)
CREATE TABLE public.fiscal_periods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_name TEXT NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    is_closed BOOLEAN DEFAULT false,
    closed_at TIMESTAMPTZ,
    closed_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Trigger to prevent modification in closed periods
CREATE OR REPLACE FUNCTION protect_closed_periods()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM fiscal_periods 
        WHERE is_closed = true 
        AND (
            (NEW.posting_date BETWEEN start_date AND end_date) OR
            (OLD.posting_date BETWEEN start_date AND end_date)
        )
    ) THEN
        RAISE EXCEPTION 'TRANSACTION BLOCKED: This fiscal period is CLOSED.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_protect_ledger_closed_periods
    BEFORE INSERT OR UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION protect_closed_periods();

-- 3. STRICT INVENTORY VALIDATION
-- Ensure inventory can never go negative at the DB level
ALTER TABLE public.inventory DROP CONSTRAINT IF EXISTS inventory_quantity_check;
ALTER TABLE public.inventory ADD CONSTRAINT inventory_quantity_check CHECK (quantity >= 0);

-- 4. DATABASE PERFORMANCE: INDEXING
CREATE INDEX IF NOT EXISTS idx_ledger_entries_party_date ON ledger_entries(party_id, posting_date);
CREATE INDEX IF NOT EXISTS idx_ledger_entries_voucher ON ledger_entries(voucher_no);
CREATE INDEX IF NOT EXISTS idx_sales_voucher ON sales(voucher_no);
CREATE INDEX IF NOT EXISTS idx_purchases_voucher ON purchases(voucher_no);

-- 5. RPC OPTIMIZATION: get_party_statement (V2.0 - High Volume Optimized)
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
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_opening_balance NUMERIC;
BEGIN
    -- 1. Optimized Opening Balance Calculation
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

    -- 2. Unioned Data for Performance (CTE)
    RETURN QUERY
    WITH aux_info AS (
        -- Pre-aggregate sales/purchases info to avoid repeated subqueries
        SELECT voucher_no, quantity as q, rate_per_unit as r, ft.name as fn
        FROM sales s JOIN fuel_types ft ON s.fuel_type_id = ft.id
        UNION ALL
        SELECT voucher_no, quantity as q, rate_per_unit as r, ft.name as fn
        FROM purchases pu JOIN fuel_types ft ON pu.fuel_type_id = ft.id
    ),
    entries AS (
        SELECT 
            le.posting_date,
            le.voucher_no,
            le.narration as particulars,
            le.voucher_type::TEXT as details,
            'Multiple'::TEXT as contra_mode, -- Simplified for performance, can be improved if needed
            ai.q as qty,
            ai.r as rate,
            le.debit_amount,
            le.credit_amount,
            SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at, le.id) + v_opening_balance as running_balance,
            ai.fn as fuel_name
        FROM ledger_entries le
        LEFT JOIN aux_info ai ON le.voucher_no = ai.voucher_no
        WHERE le.party_id = p_party_id
          AND le.is_reversed = false
          AND le.posting_date BETWEEN p_start_date AND p_end_date
    )
    -- Include Opening Row
    SELECT 
        (p_start_date - INTERVAL '1 day')::DATE,
        'OPEN'::TEXT, 'Opening Balance'::TEXT, 'Brought Forward'::TEXT, '--'::TEXT,
        NULL::NUMERIC, NULL::NUMERIC,
        CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0 END,
        CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0 END,
        v_opening_balance, NULL::TEXT
    UNION ALL
    SELECT * FROM entries
    ORDER BY 1, 10; -- Order by posting_date and running_balance logically
END;
$$;

-- 6. SECURITY HARDENING: RLS POLICY REDEFINITION
-- Drop existing relaxed policies
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT policyname, tablename 
        FROM pg_policies 
        WHERE schemaname = 'public' 
        AND policyname = 'Enable all for authenticated'
    ) LOOP
        EXECUTE 'DROP POLICY "' || r.policyname || '" ON "' || r.tablename || '"';
    END LOOP;
END $$;

-- Define Granular Policies
-- ADMIN: ALL access
-- ACCOUNTANT: SELECT on setups, SELECT/INSERT on transactions, NO DELETE/UPDATE on core records.

-- Helper for Admin
CREATE OR REPLACE FUNCTION is_admin() RETURNS BOOLEAN AS $$
  SELECT EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Helper for Accountant
CREATE OR REPLACE FUNCTION is_accountant() RETURNS BOOLEAN AS $$
  SELECT EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'accountant');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Applies to: parties, accounts, fuel_types, inventory, fiscal_periods
-- Setups: Read-only for accountants, Full for admins
CREATE POLICY "Setup View" ON parties FOR SELECT TO authenticated USING (true);
CREATE POLICY "Setup Admin" ON parties FOR ALL TO authenticated USING (is_admin());

CREATE POLICY "Accounts View" ON accounts FOR SELECT TO authenticated USING (true);
CREATE POLICY "Accounts Admin" ON accounts FOR ALL TO authenticated USING (is_admin());

CREATE POLICY "Fuel View" ON fuel_types FOR SELECT TO authenticated USING (true);
CREATE POLICY "Fuel Admin" ON fuel_types FOR ALL TO authenticated USING (is_admin());

CREATE POLICY "Inventory View" ON inventory FOR SELECT TO authenticated USING (true);
CREATE POLICY "Inventory Admin" ON inventory FOR ALL TO authenticated USING (is_admin());

CREATE POLICY "Fiscal View" ON fiscal_periods FOR SELECT TO authenticated USING (true);
CREATE POLICY "Fiscal Admin" ON fiscal_periods FOR ALL TO authenticated USING (is_admin());

-- Transactions: Select & Insert for accountants, Full for admins
CREATE POLICY "Ledger View" ON ledger_entries FOR SELECT TO authenticated USING (true);
CREATE POLICY "Ledger Insert" ON ledger_entries FOR INSERT TO authenticated WITH CHECK (is_accountant() OR is_admin());
CREATE POLICY "Ledger Admin" ON ledger_entries FOR ALL TO authenticated USING (is_admin());

CREATE POLICY "Sales View" ON sales FOR SELECT TO authenticated USING (true);
CREATE POLICY "Sales Insert" ON sales FOR INSERT TO authenticated WITH CHECK (is_accountant() OR is_admin());
CREATE POLICY "Sales Admin" ON sales FOR ALL TO authenticated USING (is_admin());

CREATE POLICY "Purchases View" ON purchases FOR SELECT TO authenticated USING (true);
CREATE POLICY "Purchases Insert" ON purchases FOR INSERT TO authenticated WITH CHECK (is_accountant() OR is_admin());
CREATE POLICY "Purchases Admin" ON purchases FOR ALL TO authenticated USING (is_admin());

CREATE POLICY "Payments View" ON payments FOR SELECT TO authenticated USING (true);
CREATE POLICY "Payments Insert" ON payments FOR INSERT TO authenticated WITH CHECK (is_accountant() OR is_admin());
CREATE POLICY "Payments Admin" ON payments FOR ALL TO authenticated USING (is_admin());

-- 7. RECONCILIATION FUNCTION
CREATE OR REPLACE FUNCTION mark_as_reconciled(p_voucher_no TEXT)
RETURNS VOID AS $$
BEGIN
    IF NOT is_admin() AND NOT is_accountant() THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Only authorized users can reconcile.';
    END IF;

    UPDATE ledger_entries
    SET reconciliation_status = true,
        reconciled_at = now()
    WHERE voucher_no = p_voucher_no;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;

-- PRODUCTION NOTES: BACKUP PROCEDURE
-- ---------------------------------
-- 1. Use 'pg_dump' for daily snapshots:
--    pg_dump -h db.supabase.co -U postgres -d postgres --table=ledger_entries --table=sales --table=purchases > daily_backup.sql
-- 2. Supabase automated backups should be enabled for PITR (Point-in-Time Recovery).
-- 3. Audit logs table exists to track sensitive changes; monitor it weekly.

-- PHASE 22: THE PRODUCTION SURGEON'S FINAL HARDENING
-- MISSION: ATOMICITY, IMMUTABILITY, CONCURRENCY-SAFETY, AND AUDIT-PROOFING
-- ---------------------------------------------------------------------------

BEGIN;

-- 1. INFRASTRUCTURE: UNIFIED SEQUENCING
-- ---------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS global_voucher_seq START 10000;

CREATE OR REPLACE FUNCTION public.get_next_voucher_no(p_prefix TEXT, p_date DATE DEFAULT CURRENT_DATE)
RETURNS TEXT AS $$
DECLARE
    v_seq_val BIGINT;
    v_date_str TEXT;
BEGIN
    v_seq_val := nextval('global_voucher_seq');
    v_date_str := to_char(p_date, 'YYYYMMDD');
    RETURN p_prefix || '-' || v_date_str || '-' || LPAD(v_seq_val::TEXT, 6, '0');
END;
$$ LANGUAGE plpgsql VOLATILE;


-- 2. CONCURRENCY & NEGATIVE PREVENTION (STOCK)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_stock_quantity(_fuel_type_id UUID, _quantity NUMERIC, _direction TEXT)
RETURNS VOID AS $$
DECLARE
    v_current_qty NUMERIC;
BEGIN
    -- LOCK THE ROW FOR ATOMICITY
    SELECT quantity INTO v_current_qty 
    FROM inventory 
    WHERE fuel_type_id = _fuel_type_id 
    FOR UPDATE;
    
    IF NOT FOUND THEN
        IF _direction = 'OUT' THEN
            RAISE EXCEPTION 'INVENTORY ERROR: No stock record found for this fuel type.';
        ELSE
            INSERT INTO inventory (fuel_type_id, quantity) VALUES (_fuel_type_id, _quantity);
            RETURN;
        END IF;
    END IF;

    IF _direction = 'OUT' THEN
        IF (v_current_qty - _quantity) < 0 THEN
             RAISE EXCEPTION 'INVENTORY BLOCKED: Insufficient stock. Current: %, Requested: %', v_current_qty, _quantity;
        END IF;

        UPDATE inventory 
        SET quantity = quantity - _quantity,
            last_updated = NOW()
        WHERE fuel_type_id = _fuel_type_id;
        
    ELSIF _direction = 'IN' THEN
        UPDATE inventory 
        SET quantity = quantity + _quantity,
            last_updated = NOW()
        WHERE fuel_type_id = _fuel_type_id;
    END IF;
END;
$$ LANGUAGE plpgsql;


-- 3. NEGATIVE ACCOUNT PREVENTION (CASH/BANK)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_account_balance_integrity()
RETURNS TRIGGER AS $$
DECLARE
    v_balance NUMERIC;
    v_account_code TEXT;
BEGIN
    SELECT code INTO v_account_code FROM accounts WHERE id = NEW.account_id;
    
    -- Strict check for Cash (1000) and Bank (1010)
    IF v_account_code IN ('1000', '1010') THEN
        SELECT COALESCE(SUM(debit_amount - credit_amount), 0) INTO v_balance
        FROM ledger_entries
        WHERE account_id = NEW.account_id;
        
        -- Include the current transaction in the check
        v_balance := v_balance + (NEW.debit_amount - NEW.credit_amount);
        
        IF v_balance < 0 THEN
            RAISE EXCEPTION 'FINANCIAL BLOCK: Account % (%) cannot have a negative balance.', v_account_code, v_balance;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_account_balance ON ledger_entries;
CREATE TRIGGER trg_check_account_balance
    AFTER INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION check_account_balance_integrity();


-- 4. IMMUTABLE LEDGER CHAINING
-- ---------------------------------------------------------------------------
-- Add columns if they don't exist
ALTER TABLE ledger_entries ADD COLUMN IF NOT EXISTS entry_hash TEXT;
ALTER TABLE ledger_entries ADD COLUMN IF NOT EXISTS prev_entry_hash TEXT;

CREATE OR REPLACE FUNCTION public.chain_ledger_entries()
RETURNS TRIGGER AS $$
DECLARE
    v_prev_hash TEXT;
BEGIN
    -- Get hash of the last entry (by created_at or ID)
    SELECT entry_hash INTO v_prev_hash
    FROM ledger_entries
    WHERE id <> NEW.id -- In case of update (though updates are blocked)
    ORDER BY created_at DESC, id DESC
    LIMIT 1;
    
    NEW.prev_entry_hash := COALESCE(v_prev_hash, 'GENESIS');
    NEW.entry_hash := md5(
        NEW.prev_entry_hash || '|' ||
        NEW.voucher_no || '|' ||
        NEW.posting_date::TEXT || '|' ||
        NEW.account_id::TEXT || '|' ||
        NEW.debit_amount::TEXT || '|' ||
        NEW.credit_amount::TEXT || '|' ||
        COALESCE(NEW.party_id::TEXT, 'NONE')
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_chain_ledger ON ledger_entries;
CREATE TRIGGER trg_chain_ledger
    BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION chain_ledger_entries();


-- 5. RE-ENFORCE RLS (STRICT SECURITY)
-- ---------------------------------------------------------------------------
ALTER TABLE parties ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE fuel_types ENABLE ROW LEVEL SECURITY;

-- Clean start for policies
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT policyname, tablename FROM pg_policies WHERE schemaname = 'public') LOOP
        EXECUTE 'DROP POLICY IF EXISTS "' || r.policyname || '" ON "' || r.tablename || '"';
    END LOOP;
END $$;

-- Defined Helpers (already exist from hardening v1, but making sure)
CREATE OR REPLACE FUNCTION is_admin() RETURNS BOOLEAN AS $$
  SELECT EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_accountant() RETURNS BOOLEAN AS $$
  SELECT EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'accountant');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Policies: ADMIN (Full Control), ACCOUNTANT (ReadOnly Setup, ReadWrite Transactions), OTHERS (None)
CREATE POLICY "Admin Full Control" ON parties FOR ALL TO authenticated USING (is_admin());
CREATE POLICY "Accountant View" ON parties FOR SELECT TO authenticated USING (is_accountant() OR is_admin());

CREATE POLICY "Admin Full Control" ON sales FOR ALL TO authenticated USING (is_admin());
CREATE POLICY "Accountant Entry" ON sales FOR INSERT TO authenticated WITH CHECK (is_accountant() OR is_admin());
CREATE POLICY "Accountant View" ON sales FOR SELECT TO authenticated USING (is_accountant() OR is_admin());

CREATE POLICY "Admin Full Control" ON purchases FOR ALL TO authenticated USING (is_admin());
CREATE POLICY "Accountant Entry" ON purchases FOR INSERT TO authenticated WITH CHECK (is_accountant() OR is_admin());
CREATE POLICY "Accountant View" ON purchases FOR SELECT TO authenticated USING (is_accountant() OR is_admin());

CREATE POLICY "Admin Full Control" ON payments FOR ALL TO authenticated USING (is_admin());
CREATE POLICY "Accountant Entry" ON payments FOR INSERT TO authenticated WITH CHECK (is_accountant() OR is_admin());
CREATE POLICY "Accountant View" ON payments FOR SELECT TO authenticated USING (is_accountant() OR is_admin());

CREATE POLICY "Admin Full Control" ON ledger_entries FOR ALL TO authenticated USING (is_admin());
CREATE POLICY "Accountant Entry" ON ledger_entries FOR INSERT TO authenticated WITH CHECK (is_accountant() OR is_admin());
CREATE POLICY "Accountant View" ON ledger_entries FOR SELECT TO authenticated USING (is_accountant() OR is_admin());

CREATE POLICY "Read All" ON accounts FOR SELECT TO authenticated USING (true);
CREATE POLICY "Admin Only Write" ON accounts FOR ALL TO authenticated USING (is_admin());

CREATE POLICY "Read All" ON inventory FOR SELECT TO authenticated USING (true);
CREATE POLICY "Admin Only Write" ON inventory FOR ALL TO authenticated USING (is_admin());

CREATE POLICY "Read All" ON fuel_types FOR SELECT TO authenticated USING (true);
CREATE POLICY "Admin Only Write" ON fuel_types FOR ALL TO authenticated USING (is_admin());


-- 6. HARDENED REPORTING (DATE-SENSITIVE)
-- ---------------------------------------------------------------------------

-- 6a. GET_BALANCE_SHEET (V3.0 - Audit Grade)
CREATE OR REPLACE FUNCTION get_balance_sheet(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE
    v_net_profit NUMERIC;
BEGIN
    -- Calculate Net Profit strictly up to date
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_net_profit
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense') 
      AND le.posting_date <= p_date
      AND le.is_reversed = false;

    RETURN QUERY
    -- ASSETS
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset' AND le.posting_date <= p_date 
      AND le.is_reversed = false AND a.code NOT IN ('1100', '1200')
    GROUP BY a.name
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL
    -- INVENTORY (Manual Account 1200)
    SELECT 'ASSETS'::TEXT, 'Stock'::TEXT, 'Fuel Inventory'::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM ledger_entries le WHERE le.account_id = (SELECT id FROM accounts WHERE code = '1200')
      AND le.posting_date <= p_date AND le.is_reversed = false

    UNION ALL
    -- RECEIVABLES
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT,
           COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM parties p
    LEFT JOIN ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date AND le.is_reversed = false
    GROUP BY p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) > 0

    UNION ALL
    -- PAYABLES
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT,
           ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
    FROM parties p
    LEFT JOIN ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date AND le.is_reversed = false
    GROUP BY p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) < 0

    UNION ALL
    -- EQUITY & PROFIT
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Net Profit'::TEXT, v_net_profit;
END;
$$ LANGUAGE plpgsql STABLE;


-- 7. REPAIR TRANSACTION RPCS (CONCURRENCY + SEQUENCE)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION create_manage_transaction(
    p_transaction_type TEXT,
    p_from_type TEXT,
    p_from_entity_id UUID,
    p_to_type TEXT,
    p_to_entity_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_transaction_date DATE
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_voucher_no TEXT;
    v_debit_account_id UUID;
    v_credit_account_id UUID;
    v_control_id UUID;
    v_result json;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    
    -- Generate Strict Voucher
    v_voucher_no := get_next_voucher_no('TRF', p_transaction_date);
    
    -- Lock Parties if involved
    IF p_from_type = 'party' THEN PERFORM 1 FROM parties WHERE id = p_from_entity_id FOR UPDATE; END IF;
    IF p_to_type = 'party' THEN PERFORM 1 FROM parties WHERE id = p_to_entity_id FOR UPDATE; END IF;

    -- Resolve Accounts
    SELECT id INTO v_control_id FROM accounts WHERE code = '1100' LIMIT 1;
    
    IF p_from_type = 'account' THEN v_credit_account_id := p_from_entity_id;
    ELSE v_credit_account_id := v_control_id; END IF;

    IF p_to_type = 'account' THEN v_debit_account_id := p_to_entity_id;
    ELSE v_debit_account_id := v_control_id; END IF;
    
    -- Lock Accounts
    PERFORM 1 FROM accounts WHERE id IN (v_debit_account_id, v_credit_account_id) FOR UPDATE;

    -- Insert entries
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES 
    (v_voucher_no, 'transfer', p_transaction_date, v_debit_account_id, CASE WHEN p_to_type = 'party' THEN p_to_entity_id ELSE NULL END, p_amount, 0, p_narration, auth.uid()),
    (v_voucher_no, 'transfer', p_transaction_date, v_credit_account_id, CASE WHEN p_from_type = 'party' THEN p_from_entity_id ELSE NULL END, 0, p_amount, p_narration, auth.uid());

    RETURN json_build_object('success', true, 'voucher_no', v_voucher_no);
END;
$$;


COMMIT;

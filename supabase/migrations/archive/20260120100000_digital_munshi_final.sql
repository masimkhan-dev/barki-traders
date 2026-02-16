-- DIGITAL MUNSHI FINAL ALIGNMENT MIGRATION
-- This script contains all the core Munshi logic, RPCs, and consistency triggers.

BEGIN;

-- 1. UTILITY: UPDATE PARTY CURRENT BALANCE TRIGGER
-- This ensures that whenever a ledger entry hits a party_id, their current_balance is updated.
CREATE OR REPLACE FUNCTION update_party_current_balance()
RETURNS TRIGGER AS $$
BEGIN
    -- Update balance for the party involved in the entry
    IF NEW.party_id IS NOT NULL THEN
        UPDATE parties 
        SET current_balance = (
            SELECT COALESCE(SUM(debit_amount) - SUM(credit_amount), 0)
            FROM ledger_entries
            WHERE party_id = NEW.party_id
        )
        WHERE id = NEW.party_id;
    END IF;

    -- If it's an update and party changed
    IF (TG_OP = 'UPDATE' OR TG_OP = 'DELETE') AND OLD.party_id IS NOT NULL AND OLD.party_id != COALESCE(NEW.party_id, '00000000-0000-0000-0000-000000000000'::uuid) THEN
        UPDATE parties 
        SET current_balance = (
            SELECT COALESCE(SUM(debit_amount) - SUM(credit_amount), 0)
            FROM ledger_entries
            WHERE party_id = OLD.party_id
        )
        WHERE id = OLD.party_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_party_balance ON public.ledger_entries;
CREATE TRIGGER trg_update_party_balance
AFTER INSERT OR UPDATE OR DELETE ON public.ledger_entries
FOR EACH ROW EXECUTE FUNCTION update_party_current_balance();


-- 2. RPC: POST MUNSHI VOUCHER (Wasooli / Adaigi)
-- Handles money movement between accounts and parties with correct control mapping.
CREATE OR REPLACE FUNCTION post_munshi_voucher(
    p_from_account_id UUID,
    p_to_account_id UUID,
    p_amount NUMERIC,
    p_narration TEXT,
    p_date DATE
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_voucher_no TEXT;
    v_debit_gl_id UUID;
    v_credit_gl_id UUID;
    v_from_is_party BOOLEAN;
    v_to_is_party BOOLEAN;
    v_party_type TEXT;
    v_receivable_id UUID;
    v_payable_id UUID;
    v_result json;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
    IF p_from_account_id = p_to_account_id THEN RAISE EXCEPTION 'From and To accounts must be different'; END IF;

    v_voucher_no := 'VCH-' || TO_CHAR(p_date, 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
    
    -- Get control accounts
    SELECT id INTO v_receivable_id FROM accounts WHERE code = '1100';
    SELECT id INTO v_payable_id FROM accounts WHERE code = '2000';

    -- Resolve FROM account
    SELECT EXISTS(SELECT 1 FROM parties WHERE id = p_from_account_id) INTO v_from_is_party;
    IF v_from_is_party THEN
        SELECT type INTO v_party_type FROM parties WHERE id = p_from_account_id;
        v_credit_gl_id := CASE WHEN v_party_type = 'supplier' THEN v_payable_id ELSE v_receivable_id END;
    ELSE
        v_credit_gl_id := p_from_account_id;
    END IF;

    -- Resolve TO account
    SELECT EXISTS(SELECT 1 FROM parties WHERE id = p_to_account_id) INTO v_to_is_party;
    IF v_to_is_party THEN
        SELECT type INTO v_party_type FROM parties WHERE id = p_to_account_id;
        v_debit_gl_id := CASE WHEN v_party_type = 'supplier' THEN v_payable_id ELSE v_receivable_id END;
    ELSE
        v_debit_gl_id := p_to_account_id;
    END IF;

    -- Insert Ledger Entries
    -- Debit Side (Receiver)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'munshi_voucher', p_date, v_debit_gl_id, CASE WHEN v_to_is_party THEN p_to_account_id ELSE NULL END, p_amount, 0, p_narration, auth.uid());
    
    -- Credit Side (Giver)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES (v_voucher_no, 'munshi_voucher', p_date, v_credit_gl_id, CASE WHEN v_from_is_party THEN p_from_account_id ELSE NULL END, 0, p_amount, p_narration, auth.uid());

    SELECT json_build_object('success', true, 'voucher_no', v_voucher_no) INTO v_result;
    RETURN v_result;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION '%', SQLERRM;
END;
$$;


-- 3. RPC: GET PARTY STATEMENT
-- Generates a chronological statement with opening balance and running balance.
DROP FUNCTION IF EXISTS get_party_statement(uuid);
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
    running_balance NUMERIC
) LANGUAGE plpgsql AS $$
DECLARE
    v_opening_balance NUMERIC;
BEGIN
    -- Get the party's opening balance from the parties table
    SELECT COALESCE(opening_balance, 0) INTO v_opening_balance FROM parties WHERE id = p_party_id;

    -- Entry 0: Opening Balance
    RETURN QUERY 
    SELECT 
        (SELECT MIN(posting_date) - INTERVAL '1 day' FROM ledger_entries WHERE party_id = p_party_id)::DATE,
        'OPEN'::TEXT,
        'Opening Balance'::TEXT,
        'Brought Forward'::TEXT,
        '--'::TEXT,
        NULL::NUMERIC, -- qty
        NULL::NUMERIC, -- rate
        CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0 END,
        CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0 END,
        v_opening_balance;

    -- Subsequent entries with running balance
    RETURN QUERY
    WITH entries AS (
        SELECT 
            le.posting_date,
            le.voucher_no,
            le.narration as particulars,
            le.voucher_type as details,
            (
                SELECT COALESCE(p.name, a.name)
                FROM ledger_entries le2
                LEFT JOIN parties p ON le2.party_id = p.id
                LEFT JOIN accounts a ON le2.account_id = a.id
                WHERE le2.voucher_no = le.voucher_no 
                AND le2.id != le.id
                LIMIT 1
            ) as contra_mode,
            NULL::NUMERIC as qty, -- Temporary placeholder for qty
            NULL::NUMERIC as rate, -- Temporary placeholder for rate
            le.debit_amount,
            le.credit_amount,
            SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at) + v_opening_balance as running_balance
        FROM ledger_entries le
        WHERE le.party_id = p_party_id
        ORDER BY le.posting_date, le.created_at
    )
    SELECT * FROM entries;
END;
$$;


-- 4. RPC: GET DAILY SUMMARY (Dashboard Stats)
DROP FUNCTION IF EXISTS get_daily_summary(date);
CREATE OR REPLACE FUNCTION get_daily_summary(target_date DATE)
RETURNS json AS $$
DECLARE
    result json;
BEGIN
    SELECT json_build_object(
        'total_sales', COALESCE((SELECT SUM(total_amount) FROM sales WHERE sale_date = target_date), 0),
        'total_sales_qty', COALESCE((SELECT SUM(quantity) FROM sales WHERE sale_date = target_date), 0),
        'total_purchases', COALESCE((SELECT SUM(total_amount) FROM purchases WHERE purchase_date = target_date), 0),
        'total_purchases_qty', COALESCE((SELECT SUM(quantity) FROM purchases WHERE purchase_date = target_date), 0),
        'cash_in', COALESCE((SELECT SUM(debit_amount) FROM ledger_entries le JOIN accounts a ON le.account_id = a.id WHERE a.code IN ('1000', '1010') AND posting_date = target_date), 0),
        'cash_out', COALESCE((SELECT SUM(credit_amount) FROM ledger_entries le JOIN accounts a ON le.account_id = a.id WHERE a.code IN ('1000', '1010') AND posting_date = target_date), 0)
    ) INTO result;
    RETURN result;
END;
$$ LANGUAGE plpgsql;


-- 5. RPC: GET PARTY PRODUCT SUMMARY (Statement Footer)
CREATE OR REPLACE FUNCTION get_party_product_summary(p_party_id UUID)
RETURNS TABLE (fuel_name TEXT, total_qty NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT f.name, SUM(q.qty)
    FROM (
        SELECT fuel_type_id, SUM(quantity) as qty FROM sales WHERE party_id = p_party_id GROUP BY fuel_type_id
        UNION ALL
        SELECT fuel_type_id, SUM(quantity) as qty FROM purchases WHERE party_id = p_party_id GROUP BY fuel_type_id
    ) q
    JOIN fuel_types f ON q.fuel_type_id = f.id
    GROUP BY f.name;
END;
$$ LANGUAGE plpgsql;

COMMIT;

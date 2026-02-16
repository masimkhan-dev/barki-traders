-- MASTER REPAIR V9: PRODUCTION-READY FDMS PROTOTYPE
-- Objective: Reset transactions, unify logic, and establish the "Munshi Standard" for UAT.

BEGIN;

-- 1. CLEAN RESET: WIPE OLD DATA (Keep Master Records)
TRUNCATE public.sales CASCADE;
TRUNCATE public.purchases CASCADE;
TRUNCATE public.payments CASCADE;
TRUNCATE public.ledger_entries CASCADE;

-- Reset Party Balances to their original Opening Balances
UPDATE public.parties SET current_balance = opening_balance;

-- 2. DROP ALL OLD FUNCTIONS TO CLEAR TYPE MISMATCHES
DROP FUNCTION IF EXISTS get_party_statement(UUID, DATE, DATE);
DROP FUNCTION IF EXISTS get_party_product_summary(UUID, DATE, DATE);
DROP FUNCTION IF EXISTS get_munshi_daily_stats(DATE);
DROP FUNCTION IF EXISTS get_stock_movement(DATE, DATE);

-- 3. MASTER TRANSACTION LOGIC: TRIGGERS
-- These triggers ensure ONE ledger entry pair per transaction.

-- 3a. SALE TRIGGER
CREATE OR REPLACE FUNCTION public.proc_sale_ledger()
RETURNS TRIGGER AS $$
DECLARE v_receivable_id UUID; v_revenue_id UUID; v_party_name TEXT;
BEGIN
    SELECT id INTO v_receivable_id FROM accounts WHERE code = '1100'; -- Accounts Receivable
    SELECT id INTO v_revenue_id FROM accounts WHERE code = '4000';    -- Sales Revenue
    SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

    -- Debit: Customer
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_receivable_id, NEW.party_id, NEW.total_amount, 0, 'Sale: ' || v_party_name || ' (' || NEW.quantity || 'L)');

    -- Credit: Sales Revenue
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Sales Revenue - ' || v_party_name);

    -- Sync Party Balance
    UPDATE parties SET current_balance = current_balance + NEW.total_amount WHERE id = NEW.party_id;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sale_ledger ON sales;
CREATE TRIGGER trg_sale_ledger AFTER INSERT ON sales FOR EACH ROW EXECUTE FUNCTION proc_sale_ledger();

-- 3b. PURCHASE TRIGGER
CREATE OR REPLACE FUNCTION public.proc_purchase_ledger()
RETURNS TRIGGER AS $$
DECLARE v_payable_id UUID; v_inventory_id UUID; v_party_name TEXT;
BEGIN
    SELECT id INTO v_payable_id FROM accounts WHERE code = '2000';   -- Accounts Payable
    SELECT id INTO v_inventory_id FROM accounts WHERE code = '1200'; -- Fuel Inventory
    SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

    -- Debit: Inventory
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_id, NULL, NEW.total_amount, 0, 'Purchase: ' || v_party_name || ' (' || NEW.quantity || 'L)');

    -- Credit: Supplier
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_payable_id, NEW.party_id, 0, NEW.total_amount, 'Credit Purchase from ' || v_party_name);

    -- Sync Party Balance (Payable increases, so current_balance becomes more CR/Negative)
    UPDATE parties SET current_balance = current_balance - NEW.total_amount WHERE id = NEW.party_id;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_purchase_ledger ON purchases;
CREATE TRIGGER trg_purchase_ledger AFTER INSERT ON purchases FOR EACH ROW EXECUTE FUNCTION proc_purchase_ledger();

-- 3c. PAYMENT TRIGGER (WASOOLI / ADAIGI)
CREATE OR REPLACE FUNCTION public.proc_payment_ledger()
RETURNS TRIGGER AS $$
DECLARE v_cash_id UUID; v_gl_id UUID; v_party_type TEXT;
BEGIN
    SELECT id INTO v_cash_id FROM accounts WHERE code = '1000';
    SELECT type INTO v_party_type FROM parties WHERE id = NEW.party_id;
    v_gl_id := CASE WHEN v_party_type = 'supplier' THEN (SELECT id FROM accounts WHERE code = '2000') ELSE (SELECT id FROM accounts WHERE code = '1100') END;

    IF NEW.payment_type = 'receipt' THEN
        -- Wasooli: Dr Cash, Cr Party
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, NEW.amount, 0, 'Cash Received - ' || NEW.notes),
               (NEW.voucher_no, 'payment', NEW.payment_date, v_gl_id, NEW.party_id, 0, NEW.amount, 'Paid by Party');
        UPDATE parties SET current_balance = current_balance - NEW.amount WHERE id = NEW.party_id;
    ELSE
        -- Adaigi: Dr Party, Cr Cash
        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
        VALUES (NEW.voucher_no, 'payment', NEW.payment_date, v_gl_id, NEW.party_id, NEW.amount, 0, 'Cash Paid to Party - ' || NEW.notes),
               (NEW.voucher_no, 'payment', NEW.payment_date, v_cash_id, NULL, 0, NEW.amount, 'Cash Out');
        UPDATE parties SET current_balance = current_balance + NEW.amount WHERE id = NEW.party_id;
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_payment_ledger ON payments;
CREATE TRIGGER trg_payment_ledger AFTER INSERT ON payments FOR EACH ROW EXECUTE FUNCTION proc_payment_ledger();

-- 4. THE MUNSHI STATEMENT (ONE ROW PER VOUCHER)
CREATE OR REPLACE FUNCTION get_party_statement(p_party_id UUID, p_start_date DATE, p_end_date DATE)
RETURNS TABLE (posting_date DATE, voucher_no TEXT, particulars TEXT, debit NUMERIC, credit NUMERIC, running_balance NUMERIC) AS $$
DECLARE v_opening_balance NUMERIC;
BEGIN
    SELECT COALESCE(pa.opening_balance, 0) + COALESCE((
        SELECT SUM(le_start.debit_amount - le_start.credit_amount) FROM ledger_entries le_start 
        WHERE le_start.party_id = p_party_id AND le_start.posting_date < p_start_date
    ), 0) INTO v_opening_balance FROM parties pa WHERE pa.id = p_party_id;

    RETURN QUERY SELECT (p_start_date - INTERVAL '1 day')::DATE, 'OPEN'::TEXT, 'Opening Balance'::TEXT, 
    CASE WHEN v_opening_balance >= 0 THEN v_opening_balance ELSE 0.0 END, 
    CASE WHEN v_opening_balance < 0 THEN ABS(v_opening_balance) ELSE 0.0 END, v_opening_balance;

    RETURN QUERY WITH raw_entries AS (
        SELECT le.posting_date, le.voucher_no, le.created_at,
        CASE 
            WHEN le.voucher_type = 'sale' THEN 'Sale'
            WHEN le.voucher_type = 'purchase' THEN 'Purchase'
            WHEN le.voucher_type = 'payment' AND le.debit_amount > 0 THEN 'Cash Paid'
            WHEN le.voucher_type = 'payment' AND le.credit_amount > 0 THEN 'Cash Received'
            ELSE le.narration END as p_txt, SUM(le.debit_amount) as dr, SUM(le.credit_amount) as cr
        FROM ledger_entries le WHERE le.party_id = p_party_id AND le.posting_date >= p_start_date AND le.posting_date <= p_end_date
        GROUP BY le.posting_date, le.voucher_no, le.voucher_type, le.narration, le.created_at
    ),
    collapsed AS (
        SELECT r.posting_date, r.voucher_no, MAX(r.p_txt) as particulars, SUM(r.dr) as debit, SUM(r.cr) as credit,
        SUM(SUM(r.dr - r.cr)) OVER (ORDER BY r.posting_date, MIN(r.created_at)) + v_opening_balance as balance
        FROM raw_entries r GROUP BY r.posting_date, r.voucher_no
    ) SELECT * FROM collapsed ORDER BY 1, 2;
END; $$ LANGUAGE plpgsql;

-- 5. STOCK MOVEMENT REPORT (Opening -> In -> Out -> Closing)
CREATE OR REPLACE FUNCTION get_stock_movement(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (fuel_name TEXT, opening_stock NUMERIC, purchased NUMERIC, sold NUMERIC, closing_stock NUMERIC) AS $$
BEGIN
    RETURN QUERY
    WITH op_stock AS (
        SELECT fuel_type_id, 
               COALESCE(SUM(CASE WHEN purchase_date < p_start_date THEN quantity ELSE 0 END), 0) -
               COALESCE(SUM(CASE WHEN sale_date < p_start_date THEN quantity ELSE 0 END), 0) as op
        FROM (SELECT fuel_type_id, quantity, purchase_date as dt, 'P' as ty FROM purchases 
              UNION ALL SELECT fuel_type_id, -quantity, sale_date as dt, 'S' as ty FROM sales) t -- This helper query is a bit simplified
        GROUP BY fuel_type_id
    )
    SELECT 
        f.name,
        COALESCE((SELECT SUM(quantity) FROM purchases WHERE fuel_type_id = f.id AND purchase_date < p_start_date), 0) -
        COALESCE((SELECT SUM(quantity) FROM sales WHERE fuel_type_id = f.id AND sale_date < p_start_date), 0) as opening,
        COALESCE((SELECT SUM(quantity) FROM purchases WHERE fuel_type_id = f.id AND purchase_date BETWEEN p_start_date AND p_end_date), 0) as purchased,
        COALESCE((SELECT SUM(quantity) FROM sales WHERE fuel_type_id = f.id AND sale_date BETWEEN p_start_date AND p_end_date), 0) as sold,
        (COALESCE((SELECT SUM(quantity) FROM purchases WHERE fuel_type_id = f.id AND purchase_date <= p_end_date), 0) -
         COALESCE((SELECT SUM(quantity) FROM sales WHERE fuel_type_id = f.id AND sale_date <= p_end_date), 0)) as closing
    FROM fuel_types f;
END; $$ LANGUAGE plpgsql;

-- 6. DASHBOARD KPI RPC
CREATE OR REPLACE FUNCTION get_munshi_daily_stats(p_date DATE)
RETURNS TABLE (total_sales NUMERIC, total_purchases NUMERIC, receivables NUMERIC, payables NUMERIC, market_balance NUMERIC) AS $$
BEGIN
    RETURN QUERY SELECT 
        (SELECT COALESCE(SUM(total_amount), 0) FROM sales WHERE sale_date = p_date),
        (SELECT COALESCE(SUM(total_amount), 0) FROM purchases WHERE purchase_date = p_date),
        (SELECT COALESCE(SUM(current_balance), 0) FROM parties WHERE current_balance > 0),
        (SELECT COALESCE(SUM(ABS(current_balance)), 0) FROM parties WHERE current_balance < 0),
        (SELECT COALESCE(SUM(current_balance), 0) FROM parties);
END; $$ LANGUAGE plpgsql;

COMMIT;
NOTIFY pgrst, 'reload config';

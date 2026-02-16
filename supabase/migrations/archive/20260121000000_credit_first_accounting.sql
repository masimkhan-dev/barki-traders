
-- CREDIT-FIRST ACCOUNTING MIGRATION
BEGIN;

-- 1. TRIGGERS FOR AUTOMATIC LEDGER ENTRIES ON SALE/PURCHASE
-- Sales: Dr Party (1100), Cr Sales (4000)
-- Purchases: Dr Inventory/Expense (5000), Cr Party (2000)

CREATE OR REPLACE FUNCTION handle_sale_ledger()
RETURNS TRIGGER AS $$
DECLARE
    v_receivable_id UUID;
    v_sales_id UUID;
BEGIN
    SELECT id INTO v_receivable_id FROM accounts WHERE code = '1100' LIMIT 1;
    SELECT id INTO v_sales_id FROM accounts WHERE code = '4000' LIMIT 1;

    -- Debit Party (Increase Receivable)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_receivable_id, NEW.party_id, NEW.total_amount, 0, 'Credit Sale: ' || NEW.notes, NEW.created_by);

    -- Credit Sales (Increase Revenue)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_sales_id, NULL, 0, NEW.total_amount, 'Sales Revenue - ' || NEW.voucher_no, NEW.created_by);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sale_ledger ON sales;
CREATE TRIGGER trg_sale_ledger
AFTER INSERT ON sales
FOR EACH ROW EXECUTE FUNCTION handle_sale_ledger();


CREATE OR REPLACE FUNCTION handle_purchase_ledger()
RETURNS TRIGGER AS $$
DECLARE
    v_payable_id UUID;
    v_purchase_id UUID;
BEGIN
    SELECT id INTO v_payable_id FROM accounts WHERE code = '2000' LIMIT 1;
    SELECT id INTO v_purchase_id FROM accounts WHERE code = '5000' LIMIT 1; -- Using 5000 for direct expense

    -- Debit Purchase/Expense (Increase Expense)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_purchase_id, NULL, NEW.total_amount, 0, 'Fuel Purchase - ' || NEW.voucher_no, NEW.created_by);

    -- Credit Party (Increase Payable)
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_payable_id, NEW.party_id, 0, NEW.total_amount, 'Credit Purchase: ' || NEW.notes, NEW.created_by);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_purchase_ledger ON purchases;
CREATE TRIGGER trg_purchase_ledger
AFTER INSERT ON purchases
FOR EACH ROW EXECUTE FUNCTION handle_purchase_ledger();


-- 2. UPDATED PARTY STATEMENT WITH SEPARATE COLUMNS
DROP FUNCTION IF EXISTS get_party_statement(uuid);
DROP FUNCTION IF EXISTS get_party_statement(uuid, date, date);

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
    sale_purchase_amount NUMERIC,
    payment_received NUMERIC,
    payment_made NUMERIC,
    running_balance NUMERIC
) LANGUAGE plpgsql AS $$
DECLARE
    v_opening_balance NUMERIC;
BEGIN
    -- Calculate opening balance by summing all entries BEFORE p_start_date
    -- Plus the base opening_balance from parties table
    SELECT 
        COALESCE(p.opening_balance, 0) + 
        COALESCE((SELECT SUM(debit_amount - credit_amount) FROM ledger_entries WHERE party_id = p_party_id AND posting_date < p_start_date), 0)
    INTO v_opening_balance
    FROM parties p
    WHERE p.id = p_party_id;

    -- Entry 0: Start Balance
    RETURN QUERY 
    SELECT 
        (p_start_date - INTERVAL '1 day')::DATE,
        'OPEN'::TEXT,
        'Start Balance'::TEXT,
        'Brought Forward'::TEXT,
        '--'::TEXT,
        NULL::NUMERIC,
        NULL::NUMERIC,
        0::NUMERIC,
        0::NUMERIC,
        0::NUMERIC,
        v_opening_balance;

    -- Period entries
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
            NULL::NUMERIC as v_qty, -- To be linked if needed
            NULL::NUMERIC as v_rate,
            -- Sale / Purchase Amount: Direct transactions
            CASE WHEN le.voucher_type IN ('sale', 'purchase') THEN (le.debit_amount + le.credit_amount) ELSE 0 END as sale_purchase,
            -- Payment Received: When party is credited (Jama) in a voucher
            CASE WHEN le.voucher_type = 'munshi_voucher' AND le.credit_amount > 0 THEN le.credit_amount ELSE 0 END as received,
            -- Payment Made: When party is debited (Udhaar) in a voucher
            CASE WHEN le.voucher_type = 'munshi_voucher' AND le.debit_amount > 0 THEN le.debit_amount ELSE 0 END as paid,
            -- Running Balance
            SUM(le.debit_amount - le.credit_amount) OVER (ORDER BY le.posting_date, le.created_at) + v_opening_balance as running_bal
        FROM ledger_entries le
        WHERE le.party_id = p_party_id
        AND le.posting_date >= p_start_date
        AND le.posting_date <= p_end_date
        ORDER BY le.posting_date, le.created_at
    )
    SELECT * FROM entries;
END;
$$;

COMMIT;

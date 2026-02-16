
-- 20260123070000_ledger_qty_rate.sql
-- Adds Quantity and Rate tracking to the General Ledger for Munshi-style reporting.

BEGIN;

-- 1. ADD COLUMNS to ledger_entries
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS quantity NUMERIC DEFAULT 0;
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS rate NUMERIC DEFAULT 0;

-- 2. UPDATE SALES TRIGGER FUNCTION
CREATE OR REPLACE FUNCTION public.proc_sale_ledger_strict()
RETURNS TRIGGER AS $$
DECLARE
    v_party_account_id UUID;
    v_revenue_id UUID;
    v_party_name TEXT;
BEGIN
    SELECT id INTO v_party_account_id FROM accounts WHERE code = '1100'; -- Unified Party Ledger
    SELECT id INTO v_revenue_id FROM accounts WHERE code = '4000';       -- Sales Revenue
    SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

    -- 1. GL ENTRIES
    -- Party Side (Receivable) - We store Qty and Rate here for the Ledger Report
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_party_account_id, NEW.party_id, NEW.total_amount, 0, 'Sale to ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

    -- Revenue Side
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sales Revenue', NEW.quantity, NEW.rate_per_unit);

    -- 2. STOCK UPDATE
    PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'OUT');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. UPDATE PURCHASE TRIGGER FUNCTION
CREATE OR REPLACE FUNCTION public.proc_purchase_ledger_strict()
RETURNS TRIGGER AS $$
DECLARE
    v_party_account_id UUID;
    v_purchase_account_id UUID;
    v_party_name TEXT;
BEGIN
    SELECT id INTO v_party_account_id FROM accounts WHERE code = '1100'; -- Unified Party Ledger
    SELECT id INTO v_purchase_account_id FROM accounts WHERE code = '5000';
    IF v_purchase_account_id IS NULL THEN
        SELECT id INTO v_purchase_account_id FROM accounts WHERE code = '1200';
    END IF;
    
    SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

    -- 1. GL ENTRIES
    -- Expense/Inventory Side
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_purchase_account_id, NULL, NEW.total_amount, 0, 'Purchase from ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

    -- Party Side (Payable) - Store Qty and Rate here
    INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_party_account_id, NEW.party_id, 0, NEW.total_amount, 'Credit Purchase - ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

    -- 2. STOCK UPDATE
    PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'IN');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 4. UPDATE get_party_statement RPC
DROP FUNCTION IF EXISTS public.get_party_statement(UUID, DATE, DATE);

CREATE OR REPLACE FUNCTION public.get_party_statement(p_party_id UUID, p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    posting_date DATE, 
    voucher_no TEXT, 
    particulars TEXT, 
    quantity NUMERIC,
    rate NUMERIC,
    debit NUMERIC, 
    credit NUMERIC, 
    running_balance NUMERIC
) AS $$
DECLARE 
    v_opening_balance NUMERIC := 0;
BEGIN
    -- 1. CALCULATE OPENING BALANCE
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

    -- 2. RETURN OPENING ROW
    RETURN QUERY SELECT 
        (p_start_date - INTERVAL '1 day')::DATE as posting_date,
        'OPENING'::TEXT as voucher_no,
        'Opening Balance B/F'::TEXT as particulars,
        0.0::NUMERIC as quantity,
        0.0::NUMERIC as rate,
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
            le.quantity,
            le.rate,
            le.created_at
        FROM ledger_entries le
        WHERE le.party_id = p_party_id 
          AND le.posting_date BETWEEN p_start_date AND p_end_date
          AND (le.debit_amount != 0 OR le.credit_amount != 0)
    ),
    grouped_tx AS (
        SELECT 
            r.posting_date,
            r.voucher_no,
            string_agg(DISTINCT r.narration, ' | ') as narration,
            -- Max is fine for qty/rate since we group by voucher and vouchers are generally single fuel type per ledger entry row
            MAX(r.quantity) as quantity,
            MAX(r.rate) as rate,
            CASE 
                WHEN COUNT(DISTINCT r.voucher_type) > 1 THEN 'Adjustment/Mixed'
                WHEN MAX(r.voucher_type) = 'sale' THEN 'Fuel Sale'
                WHEN MAX(r.voucher_type) = 'purchase' THEN 'Fuel Purchase'
                WHEN MAX(r.voucher_type) = 'payment' THEN 
                    CASE 
                        WHEN SUM(r.debit_amount) > SUM(r.credit_amount) THEN 'Payment (Dr)'
                        ELSE 'Payment (Cr)'
                    END
                ELSE MAX(r.voucher_type)
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
        (g.type_label || ' - ' || g.narration)::TEXT as particulars,
        g.quantity,
        g.rate,
        ROUND(g.total_debit, 2) as debit,
        ROUND(g.total_credit, 2) as credit,
        ROUND(
            (SUM(g.total_debit - g.total_credit) OVER (ORDER BY g.posting_date, g.sort_time, g.voucher_no) + v_opening_balance), 
            2
        )::NUMERIC
    FROM grouped_tx g
    ORDER BY g.posting_date, g.sort_time, g.voucher_no;

END;
$$ LANGUAGE plpgsql;

-- 5. BACKFILL EXISTING DATA
-- Update sales
UPDATE ledger_entries le
SET quantity = s.quantity,
    rate = s.rate_per_unit
FROM sales s
WHERE le.voucher_no = s.voucher_no AND le.voucher_type = 'sale';

-- Update purchases
UPDATE ledger_entries le
SET quantity = p.quantity,
    rate = p.rate_per_unit
FROM purchases p
WHERE le.voucher_no = p.voucher_no AND le.voucher_type = 'purchase';

COMMIT;

-- =================================================================
-- FDMS PRODUCTION READINESS HOTFIX (Jan 30, 2026)
-- Target: Corrects Ledger Drift, Racial Voucher Risks, and Statement Gaps
-- =================================================================

BEGIN;

-- 1. SCHEMA RESTORATION (SAFELY ADD MISSING COLUMNS)
-- Ensure ledger has Qty/Rate (dropped in earlier migrations)
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS quantity NUMERIC DEFAULT 0;
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS rate NUMERIC DEFAULT 0;
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS reconciliation_status BOOLEAN DEFAULT false;
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS reconciled_at TIMESTAMPTZ;

-- 2. PERFORMANCE OPTIMIZATION (COMPOSITE INDEXES)
-- Critical for fast statements and roznamcha
CREATE INDEX IF NOT EXISTS idx_ledger_party_date ON public.ledger_entries(party_id, posting_date);
CREATE INDEX IF NOT EXISTS idx_ledger_account_date ON public.ledger_entries(account_id, posting_date);
CREATE INDEX IF NOT EXISTS idx_sales_date_composite ON public.sales(sale_date, id);
CREATE INDEX IF NOT EXISTS idx_purchases_date_composite ON public.purchases(purchase_date, id);

-- 3. VOUCHER NUMBERING (SEQUENCE BASED - PREVENTS RACE CONDITIONS)
CREATE SEQUENCE IF NOT EXISTS voucher_seq_sale_v2 START 1001;
CREATE SEQUENCE IF NOT EXISTS voucher_seq_purchase_v2 START 1001;
CREATE SEQUENCE IF NOT EXISTS voucher_seq_payment_v2 START 1001;

CREATE OR REPLACE FUNCTION public.fn_generate_voucher_no()
RETURNS TRIGGER AS $$
DECLARE
    v_prefix TEXT;
    v_date_str TEXT;
    v_seq_name TEXT;
    v_num BIGINT;
BEGIN
    -- Only generate if voucher_no is NULL or empty
    IF NEW.voucher_no IS NOT NULL AND NEW.voucher_no <> '' THEN
        RETURN NEW;
    END IF;

    v_date_str := to_char(COALESCE(NEW.sale_date, NEW.purchase_date, NEW.payment_date, CURRENT_DATE), 'YYYYMMDD');
    
    IF TG_TABLE_NAME = 'sales' THEN 
        v_prefix := 'SAL'; v_seq_name := 'voucher_seq_sale_v2';
    ELSIF TG_TABLE_NAME = 'purchases' THEN 
        v_prefix := 'PUR'; v_seq_name := 'voucher_seq_purchase_v2';
    ELSIF TG_TABLE_NAME = 'payments' THEN 
        v_prefix := CASE WHEN NEW.payment_type = 'receipt' THEN 'RCP' ELSE 'PMT' END;
        v_seq_name := 'voucher_seq_payment_v2';
    ELSE 
        v_prefix := 'GEN'; v_seq_name := 'voucher_seq_payment_v2';
    END IF;

    EXECUTE format('SELECT nextval(%L)', v_seq_name) INTO v_num;
    NEW.voucher_no := v_prefix || '-' || v_date_str || '-' || lpad(v_num::text, 4, '0');
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply naming triggers to sub-ledgers
DROP TRIGGER IF EXISTS trigger_sales_autoname ON public.sales;
CREATE TRIGGER trigger_sales_autoname BEFORE INSERT ON public.sales FOR EACH ROW EXECUTE FUNCTION fn_generate_voucher_no();

DROP TRIGGER IF EXISTS trigger_purchases_autoname ON public.purchases;
CREATE TRIGGER trigger_purchases_autoname BEFORE INSERT ON public.purchases FOR EACH ROW EXECUTE FUNCTION fn_generate_voucher_no();

DROP TRIGGER IF EXISTS trigger_payments_autoname ON public.payments;
CREATE TRIGGER trigger_payments_autoname BEFORE INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION fn_generate_voucher_no();


-- 4. BUSINESS LOGIC: POSTING WITH QTY & RATE
-- Update Sale Posting Trigger
CREATE OR REPLACE FUNCTION public.auto_post_sale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ar_id UUID;
    v_revenue_id UUID;
    v_inventory_id UUID;
    v_cogs_id UUID;
    v_current_stock NUMERIC;
    v_avg_cost NUMERIC;
    v_cogs_amount NUMERIC;
BEGIN
    SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
    SELECT id INTO v_revenue_id FROM public.accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_inventory_id FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM public.accounts WHERE slug = 'cogs';
    
    -- Stock check
    SELECT quantity, avg_cost INTO v_current_stock, v_avg_cost
    FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;
    
    IF v_current_stock < NEW.quantity THEN
        RAISE EXCEPTION 'Insufficient stock. Have: %, Need: %', v_current_stock, NEW.quantity;
    END IF;

    v_cogs_amount := NEW.quantity * v_avg_cost;

    -- 1. AR Entry (With Qty/Rate)
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_ar_id, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale - Credit', NEW.quantity, NEW.rate_per_unit);

    -- 2. Revenue Entry
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sale Revenue');

    -- 3. COGS & Inventory Entry
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
    VALUES 
        (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL, v_cogs_amount, 0, 'COGS - Sale'),
        (NEW.voucher_no, 'sale', NEW.sale_date, v_inventory_id, NULL, 0, v_cogs_amount, 'Inventory Reduction');

    -- Update inventory
    UPDATE public.inventory SET quantity = quantity - NEW.quantity WHERE fuel_type_id = NEW.fuel_type_id;
    
    RETURN NEW;
END;
$$;

-- Update Purchase Posting Trigger
CREATE OR REPLACE FUNCTION public.update_inventory_on_purchase()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    current_qty NUMERIC;
    current_avg_cost NUMERIC;
    new_avg_cost NUMERIC;
    v_inventory_acct UUID;
    v_ap_acct UUID;
BEGIN
    SELECT quantity, avg_cost INTO current_qty, current_avg_cost FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;
    IF NOT FOUND THEN current_qty := 0; current_avg_cost := 0; END IF;

    IF (current_qty + NEW.quantity) > 0 THEN
        new_avg_cost := ((current_qty * current_avg_cost) + (NEW.quantity * NEW.rate_per_unit)) / (current_qty + NEW.quantity);
    ELSE
        new_avg_cost := NEW.rate_per_unit;
    END IF;

    -- Update Inventory record
    INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost, last_updated)
    VALUES (NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit, NOW())
    ON CONFLICT (fuel_type_id) DO UPDATE
    SET quantity = inventory.quantity + EXCLUDED.quantity, avg_cost = new_avg_cost, last_updated = NOW();

    SELECT id INTO v_inventory_acct FROM public.accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap_acct FROM public.accounts WHERE slug = 'ap';

    -- 1. Inventory Asset Entry (With Qty/Rate)
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inventory_acct, NULL, NEW.total_amount, 0, 'Inventory Purchase', NEW.quantity, NEW.rate_per_unit);

    -- 2. AP Payable Entry
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
    VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_acct, NEW.party_id, 0, NEW.total_amount, 'Purchase from Supplier', NEW.quantity, NEW.rate_per_unit);

    RETURN NEW;
END;
$$;

-- 5. REPORTING: AUDIT-GRADE PARTY STATEMENT
DROP FUNCTION IF EXISTS public.get_party_statement(UUID, DATE, DATE);
CREATE OR REPLACE FUNCTION public.get_party_statement(
    p_party_id UUID, 
    p_start_date DATE DEFAULT '2000-01-01', 
    p_end_date DATE DEFAULT CURRENT_DATE
)
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
    v_opening_bal NUMERIC;
BEGIN
    -- Calculate opening balance up to p_start_date
    SELECT 
        COALESCE(p.opening_balance, 0) + 
        COALESCE((
            SELECT SUM(le.debit_amount - le.credit_amount)
            FROM public.ledger_entries le
            WHERE le.party_id = p_party_id 
              AND le.posting_date < p_start_date
              AND (le.is_reversed IS NULL OR le.is_reversed = false)
        ), 0)
    INTO v_opening_bal
    FROM public.parties p
    WHERE p.id = p_party_id;

    -- 1. Opening Row
    RETURN QUERY SELECT 
        p_start_date,
        'OPEN'::TEXT,
        'B/F Opening Balance'::TEXT,
        0::NUMERIC, 0::NUMERIC,
        CASE WHEN v_opening_bal >= 0 THEN v_opening_bal ELSE 0 END,
        CASE WHEN v_opening_bal < 0 THEN ABS(v_opening_bal) ELSE 0 END,
        v_opening_bal;

    -- 2. Transaction Rows
    RETURN QUERY
    WITH tx_data AS (
        SELECT 
            le.posting_date, le.voucher_no, le.narration,
            le.quantity, le.rate, le.debit_amount, le.credit_amount,
            le.created_at
        FROM public.ledger_entries le
        WHERE le.party_id = p_party_id
          AND le.posting_date BETWEEN p_start_date AND p_end_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
        ORDER BY le.posting_date ASC, le.created_at ASC
    )
    SELECT 
        t.posting_date, t.voucher_no, t.narration,
        t.quantity, t.rate, t.debit_amount, t.credit_amount,
        (v_opening_bal + SUM(t.debit_amount - t.credit_amount) OVER (ORDER BY t.posting_date, t.created_at))
    FROM tx_data t;
END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;

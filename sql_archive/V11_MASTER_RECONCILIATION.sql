-- ==========================================
-- 🚀 V11 MASTER RECONCILIATION & REPAIR (FINAL)
-- ==========================================
-- 1. Restore Chart of Accounts (Slugs & Codes)
-- 2. Restore V11 Smart Triggers (Clean & Reliable)
-- 3. Data Sync: Rebuild Ledger from Sub-ledgers (Fix missing entries)
-- 4. Report Harmonization (Include Opening Balances)

BEGIN;

--------------------------------------------------------------------------------
-- SECTION 1: ACCOUNT INFRASTRUCTURE (RECONCILED SLUGS)
--------------------------------------------------------------------------------
DO $$
BEGIN
    -- 1. Temporarily clear all targeted slugs to avoid unique constraint violations during reassignment
    UPDATE public.accounts 
    SET slug = NULL 
    WHERE slug IN ('cash', 'bank', 'ar', 'ap', 'inventory', 'sales_revenue', 'cogs', 'capital');

    -- 2. Assign 'cash' to the primary cash account (Code 1000 or the first matching name)
    UPDATE public.accounts SET slug = 'cash' WHERE id = (
        SELECT id FROM public.accounts WHERE code = '1000' OR name ILIKE 'Cash on Hand' LIMIT 1
    );

    -- 3. Assign 'bank'
    UPDATE public.accounts SET slug = 'bank' WHERE id = (
        SELECT id FROM public.accounts WHERE code = '1010' OR name ILIKE 'Bank Account%' LIMIT 1
    );

    -- 4. Assign 'ar'
    UPDATE public.accounts SET slug = 'ar' WHERE id = (
        SELECT id FROM public.accounts WHERE code = '1100' OR name ILIKE 'Accounts Receivable%' LIMIT 1
    );

    -- 5. Assign 'ap'
    UPDATE public.accounts SET slug = 'ap' WHERE id = (
        SELECT id FROM public.accounts WHERE code = '2100' OR code = '2000' OR name ILIKE 'Accounts Payable%' LIMIT 1
    );

    -- 6. Assign 'inventory'
    UPDATE public.accounts SET slug = 'inventory' WHERE id = (
        SELECT id FROM public.accounts WHERE code = '1200' OR name ILIKE '%Inventory%' OR name ILIKE 'Fuel Purchase%' LIMIT 1
    );

    -- 7. Assign 'sales_revenue'
    UPDATE public.accounts SET slug = 'sales_revenue' WHERE id = (
        SELECT id FROM public.accounts WHERE code = '3100' OR code = '4000' OR name ILIKE 'Sales Revenue%' LIMIT 1
    );

    -- 8. Assign 'cogs'
    UPDATE public.accounts SET slug = 'cogs' WHERE id = (
        SELECT id FROM public.accounts WHERE code = '4100' OR code = '5000' OR name ILIKE 'Cost of Goods Sold%' LIMIT 1
    );

    -- 9. Assign 'capital'
    UPDATE public.accounts SET slug = 'capital' WHERE id = (
        SELECT id FROM public.accounts WHERE code = '3010' OR code = '3000' OR name ILIKE '%Capital%' LIMIT 1
    );
END $$;

--------------------------------------------------------------------------------
-- SECTION 2: TRIGGER HARDENING (V11)
--------------------------------------------------------------------------------

-- Helper for permission
CREATE OR REPLACE FUNCTION public.check_v11_permission(p_action TEXT)
RETURNS BOOLEAN AS $$
DECLARE v_role TEXT;
BEGIN
    SELECT role INTO v_role FROM public.user_roles WHERE user_id = auth.uid();
    IF p_action = 'DELETE' AND COALESCE(v_role, '') != 'admin' THEN
        RAISE EXCEPTION 'PERMISSION DENIED: Only Admin can delete records.';
    END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PURCHASE TRIGGER
CREATE OR REPLACE FUNCTION public.sync_purchase_v11()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_inv UUID; v_ap UUID;
BEGIN
    PERFORM public.check_v11_permission(TG_OP);
    SELECT id INTO v_inv FROM public.accounts WHERE slug = 'inventory' LIMIT 1;
    SELECT id INTO v_ap FROM public.accounts WHERE slug = 'ap' LIMIT 1;

    IF (TG_OP = 'DELETE') THEN
        UPDATE public.inventory SET quantity = quantity - OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        RETURN OLD;
    END IF;

    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        IF TG_OP = 'UPDATE' THEN
            UPDATE public.inventory SET quantity = quantity - OLD.quantity + NEW.quantity WHERE fuel_type_id = NEW.fuel_type_id;
            DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        ELSE
            INSERT INTO public.inventory (fuel_type_id, quantity, avg_cost)
            VALUES (NEW.fuel_type_id, NEW.quantity, NEW.rate_per_unit)
            ON CONFLICT (fuel_type_id) DO UPDATE SET 
                avg_cost = ((inventory.quantity * inventory.avg_cost) + (NEW.quantity * NEW.rate_per_unit)) / NULLIF(inventory.quantity + NEW.quantity, 0),
                quantity = inventory.quantity + NEW.quantity;
        END IF;

        IF v_inv IS NOT NULL AND v_ap IS NOT NULL THEN
            INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
            VALUES 
                (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv, NULL, NEW.total_amount, 0, 'Inventory Purchase [' || NEW.voucher_no || ']', NEW.created_by),
                (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap, NEW.party_id, 0, NEW.total_amount, 'Purchase from Supplier', NEW.created_by);
        END IF;
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;

-- SALE TRIGGER
CREATE OR REPLACE FUNCTION public.sync_sale_v11()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_inv UUID; v_cogs UUID; v_rev UUID; v_ar UUID; v_avg NUMERIC;
BEGIN
    PERFORM public.check_v11_permission(TG_OP);
    SELECT id INTO v_inv FROM public.accounts WHERE slug = 'inventory' LIMIT 1;
    SELECT id INTO v_cogs FROM public.accounts WHERE slug = 'cogs' LIMIT 1;
    SELECT id INTO v_rev FROM public.accounts WHERE slug = 'sales_revenue' LIMIT 1;
    SELECT id INTO v_ar FROM public.accounts WHERE slug = 'ar' LIMIT 1;

    IF (TG_OP = 'DELETE') THEN
        UPDATE public.inventory SET quantity = quantity + OLD.quantity WHERE fuel_type_id = OLD.fuel_type_id;
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        RETURN OLD;
    END IF;

    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        IF TG_OP = 'UPDATE' THEN
            UPDATE public.inventory SET quantity = quantity + OLD.quantity - NEW.quantity WHERE fuel_type_id = NEW.fuel_type_id;
            DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        ELSE
            UPDATE public.inventory SET quantity = quantity - NEW.quantity WHERE fuel_type_id = NEW.fuel_type_id;
        END IF;

        SELECT COALESCE(avg_cost, 0) INTO v_avg FROM public.inventory WHERE fuel_type_id = NEW.fuel_type_id;

        IF v_ar IS NOT NULL AND v_rev IS NOT NULL THEN
            INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
            VALUES 
                (NEW.voucher_no, 'sale', NEW.sale_date, v_ar, NEW.party_id, NEW.total_amount, 0, 'Fuel Sale (Credit) [' || NEW.voucher_no || ']', NEW.created_by),
                (NEW.voucher_no, 'sale', NEW.sale_date, v_rev, NULL, 0, NEW.total_amount, 'Sales Revenue', NEW.created_by);
            
            IF v_cogs IS NOT NULL AND v_inv IS NOT NULL THEN
                INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
                VALUES 
                    (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs, NULL, (NEW.quantity * v_avg), 0, 'Cost of Goods Sold', NEW.created_by),
                    (NEW.voucher_no, 'sale', NEW.sale_date, v_inv, NULL, 0, (NEW.quantity * v_avg), 'Inventory Reduction (COGS)', NEW.created_by);
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;

-- RE-ATTACH TRIGGERS
DROP TRIGGER IF EXISTS sync_purchase_v11_trigger ON public.purchases;
CREATE TRIGGER sync_purchase_v11_trigger AFTER INSERT OR UPDATE OR DELETE ON public.purchases FOR EACH ROW EXECUTE FUNCTION public.sync_purchase_v11();

DROP TRIGGER IF EXISTS sync_sale_v11_trigger ON public.sales;
CREATE TRIGGER sync_sale_v11_trigger AFTER INSERT OR UPDATE OR DELETE ON public.sales FOR EACH ROW EXECUTE FUNCTION public.sync_sale_v11();

--------------------------------------------------------------------------------
-- SECTION 3: DATA RECOVERY (Sync missing Ledger entries)
--------------------------------------------------------------------------------
-- 1. Recover missing Purchase entries
INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
SELECT p.voucher_no, 'purchase', p.purchase_date, a.id, NULL, p.total_amount, 0, 'Inventory Purchase (RECOVERED)'
FROM public.purchases p
CROSS JOIN public.accounts a
WHERE a.slug = 'inventory'
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = p.voucher_no);

INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
SELECT p.voucher_no, 'purchase', p.purchase_date, a.id, p.party_id, 0, p.total_amount, 'Purchase from Supplier (RECOVERED)'
FROM public.purchases p
CROSS JOIN public.accounts a
WHERE a.slug = 'ap'
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = p.voucher_no AND party_id = p.party_id);

-- 2. Recover missing Sale entries
INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
SELECT s.voucher_no, 'sale', s.sale_date, a.id, s.party_id, s.total_amount, 0, 'Fuel Sale (RECOVERED)'
FROM public.sales s
CROSS JOIN public.accounts a
WHERE a.slug = 'ar'
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = s.voucher_no AND party_id = s.party_id);

INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
SELECT s.voucher_no, 'sale', s.sale_date, a.id, NULL, 0, s.total_amount, 'Sales Revenue (RECOVERED)'
FROM public.sales s
CROSS JOIN public.accounts a
WHERE a.slug = 'sales_revenue'
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = s.voucher_no AND account_id = a.id);

-- 3. Recover missing Payment/Receipt entries
INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
SELECT p.voucher_no, p.payment_type, p.payment_date, a.id, NULL, p.amount, 0, 'Cash Receipt (RECOVERED)'
FROM public.payments p
CROSS JOIN public.accounts a
WHERE a.slug = 'cash' AND p.payment_type = 'receipt'
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = p.voucher_no AND account_id = a.id);

INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
SELECT p.voucher_no, p.payment_type, p.payment_date, a.id, p.party_id, 0, p.amount, 'Receipt from Customer (RECOVERED)'
FROM public.payments p
CROSS JOIN public.accounts a
WHERE a.slug = 'ar' AND p.payment_type = 'receipt'
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = p.voucher_no AND party_id = p.party_id);

INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
SELECT p.voucher_no, p.payment_type, p.payment_date, a.id, p.party_id, p.amount, 0, 'Payment to Supplier (RECOVERED)'
FROM public.payments p
CROSS JOIN public.accounts a
WHERE a.slug = 'ap' AND p.payment_type = 'payment'
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = p.voucher_no AND party_id = p.party_id);

INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration)
SELECT p.voucher_no, p.payment_type, p.payment_date, a.id, NULL, 0, p.amount, 'Cash Payment (RECOVERED)'
FROM public.payments p
CROSS JOIN public.accounts a
WHERE a.slug = 'cash' AND p.payment_type = 'payment'
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = p.voucher_no AND account_id = a.id);

--------------------------------------------------------------------------------
-- SECTION 4: HARMONIZED REPORTING
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_trial_balance_v2(DATE, DATE);

CREATE OR REPLACE FUNCTION public.get_trial_balance_v2(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    account_type TEXT,
    opening_balance NUMERIC,
    debit_total NUMERIC,
    credit_total NUMERIC,
    debit_balance NUMERIC,
    credit_balance NUMERIC
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    WITH all_entities AS (
        SELECT 
            a.id as entity_id, 'account' as entity_type, a.code::TEXT as ac, a.name::TEXT as an, a.account_type::TEXT as at, 0::NUMERIC as base_opening
        FROM public.accounts a WHERE a.is_active = true AND a.slug NOT IN ('ar', 'ap')
        UNION ALL
        SELECT 
            p.id as entity_id, 'party' as entity_type, (CASE WHEN p.type='customer' THEN '1100-' ELSE '2100-' END || LEFT(p.id::text, 8))::TEXT as ac, (p.name || ' (' || UPPER(LEFT(p.type, 1)) || ')')::TEXT as an, (CASE WHEN p.type='customer' THEN 'asset' ELSE 'liability' END)::TEXT as at, COALESCE(p.opening_balance, 0) as base_opening
        FROM public.parties p WHERE p.is_active = true 
    ),
    ledger_sum AS (
        SELECT 
            ae.entity_id, ae.entity_type,
            SUM(CASE WHEN (p_start_date IS NOT NULL AND le.posting_date < p_start_date) THEN le.debit_amount - le.credit_amount ELSE 0 END) as ledger_op,
            SUM(CASE WHEN (p_start_date IS NULL OR le.posting_date >= p_start_date) AND (p_end_date IS NULL OR le.posting_date <= p_end_date) THEN le.debit_amount ELSE 0 END) as dr,
            SUM(CASE WHEN (p_start_date IS NULL OR le.posting_date >= p_start_date) AND (p_end_date IS NULL OR le.posting_date <= p_end_date) THEN le.credit_amount ELSE 0 END) as cr
        FROM all_entities ae
        LEFT JOIN public.ledger_entries le ON (ae.entity_type = 'account' AND le.account_id = ae.entity_id) OR (ae.entity_type = 'party' AND le.party_id = ae.entity_id)
        WHERE (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY ae.entity_id, ae.entity_type
    ),
    calc AS (
        SELECT 
            ae.ac, ae.an, ae.at, (ae.base_opening + COALESCE(ls.ledger_op, 0))::NUMERIC as op, COALESCE(ls.dr, 0)::NUMERIC as dr, COALESCE(ls.cr, 0)::NUMERIC as cr
        FROM all_entities ae
        LEFT JOIN ledger_sum ls ON ae.entity_id = ls.entity_id AND ae.entity_type = ls.entity_type
    )
    SELECT 
        c.ac, c.an, c.at, c.op, c.dr, c.cr,
        CASE WHEN (c.op + c.dr - c.cr) > 0 THEN (c.op + c.dr - c.cr) ELSE 0 END,
        CASE WHEN (c.op + c.dr - c.cr) < 0 THEN ABS(c.op + c.dr - c.cr) ELSE 0 END
    FROM calc c
    WHERE c.dr != 0 OR c.cr != 0 OR c.op != 0
    ORDER BY c.ac;
END;
$$;

COMMIT;

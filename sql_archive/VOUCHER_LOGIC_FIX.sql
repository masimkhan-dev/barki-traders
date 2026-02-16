-- =================================================================
-- PRODUCTION HOTFIX PATCH (Voucher Logic Fix)
-- Purpose: Corrects "Missing field" error in the voucher generator
-- =================================================================

BEGIN;

-- 1. Corrected Voucher Generator Function
-- This function now safely checks the table context before accessing fields
CREATE OR REPLACE FUNCTION public.fn_generate_voucher_no()
RETURNS TRIGGER AS $$
DECLARE
    v_prefix TEXT;
    v_date_str TEXT;
    v_seq_name TEXT;
    v_num BIGINT;
    v_posted_date DATE;
BEGIN
    -- Stop if voucher_no is already provided
    IF NEW.voucher_no IS NOT NULL AND NEW.voucher_no <> '' THEN
        RETURN NEW;
    END IF;

    -- Determine the correct date field and seq based on table
    IF TG_TABLE_NAME = 'sales' THEN 
        v_prefix := 'SAL'; 
        v_seq_name := 'voucher_seq_sale_v2';
        v_posted_date := NEW.sale_date;
    ELSIF TG_TABLE_NAME = 'purchases' THEN 
        v_prefix := 'PUR'; 
        v_seq_name := 'voucher_seq_purchase_v2';
        v_posted_date := NEW.purchase_date;
    ELSIF TG_TABLE_NAME = 'payments' THEN 
        v_prefix := CASE WHEN NEW.payment_type = 'receipt' THEN 'RCP' ELSE 'PMT' END;
        v_seq_name := 'voucher_seq_payment_v2';
        v_posted_date := NEW.payment_date;
    ELSE 
        v_prefix := 'GEN'; 
        v_seq_name := 'voucher_seq_payment_v2';
        v_posted_date := CURRENT_DATE;
    END IF;

    v_date_str := to_char(COALESCE(v_posted_date, CURRENT_DATE), 'YYYYMMDD');

    -- Get next sequence number
    EXECUTE format('SELECT nextval(%L)', v_seq_name) INTO v_num;
    
    -- Format: PRFX-YYYYMMDD-0001
    NEW.voucher_no := v_prefix || '-' || v_date_str || '-' || lpad(v_num::text, 4, '0');
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. Verify Triggers exist (Just in case they were dropped)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trigger_sales_autoname') THEN
        CREATE TRIGGER trigger_sales_autoname BEFORE INSERT ON public.sales FOR EACH ROW EXECUTE FUNCTION fn_generate_voucher_no();
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trigger_purchases_autoname') THEN
        CREATE TRIGGER trigger_purchases_autoname BEFORE INSERT ON public.purchases FOR EACH ROW EXECUTE FUNCTION fn_generate_voucher_no();
    END IF;
END $$;

COMMIT;

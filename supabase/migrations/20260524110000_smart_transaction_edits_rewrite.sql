BEGIN;

SET search_path = public;

-- 1. Re-enable Permissions
GRANT UPDATE, DELETE ON public.sales TO authenticated;
GRANT UPDATE, DELETE ON public.purchases TO authenticated;
GRANT UPDATE, DELETE ON public.ledger_entries TO authenticated;

-- 2. SMART SALES TRIGGER (Replacing proc_sale_ledger_strict)
-- Note: We must ensure it triggers on UPDATE and DELETE as well.
DROP TRIGGER IF EXISTS trg_sale_ledger_strict ON public.sales;
DROP TRIGGER IF EXISTS trg_sale_ledger_final ON public.sales;

CREATE OR REPLACE FUNCTION public.proc_sale_ledger_strict()
RETURNS TRIGGER AS $$
DECLARE
    v_party_account_id UUID;
    v_revenue_id UUID;
    v_party_name TEXT;
    v_delta NUMERIC;
BEGIN
    SELECT id INTO v_party_account_id FROM accounts WHERE code = '1100';
    SELECT id INTO v_revenue_id FROM accounts WHERE code = '4000';
    
    IF TG_OP = 'INSERT' THEN
        SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
        VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_party_account_id, NEW.party_id, NEW.total_amount, 0, 'Sale to ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
        VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sales Revenue', NEW.quantity, NEW.rate_per_unit);

        PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'OUT');

        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        -- Safely return stock
        PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'IN');
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        -- Smart Edit bypass for stock
        IF NEW.fuel_type_id IS DISTINCT FROM OLD.fuel_type_id THEN
            -- Full return of old, deduct new
            PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'IN');
            PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'OUT');
        ELSIF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
            v_delta := NEW.quantity - OLD.quantity;
            IF v_delta > 0 THEN
                -- Sold more, deduct from stock
                PERFORM public.update_stock_quantity(NEW.fuel_type_id, v_delta, 'OUT');
            ELSIF v_delta < 0 THEN
                -- Sold less, return to stock
                PERFORM public.update_stock_quantity(NEW.fuel_type_id, abs(v_delta), 'IN');
            END IF;
        END IF;

        -- Handle Ledger Rebuild
        IF NEW.total_amount IS DISTINCT FROM OLD.total_amount 
           OR NEW.rate_per_unit IS DISTINCT FROM OLD.rate_per_unit
           OR NEW.quantity IS DISTINCT FROM OLD.quantity
           OR NEW.sale_date IS DISTINCT FROM OLD.sale_date
           OR NEW.party_id IS DISTINCT FROM OLD.party_id THEN
            
            SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;
            
            DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
            VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_party_account_id, NEW.party_id, NEW.total_amount, 0, 'Sale to ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
            VALUES (NEW.voucher_no, 'sale', NEW.sale_date, v_revenue_id, NULL, 0, NEW.total_amount, 'Fuel Sales Revenue', NEW.quantity, NEW.rate_per_unit);
        ELSE
            -- Narration only update
            UPDATE public.ledger_entries 
            SET narration = COALESCE(NEW.notes, 'Sale to ' || (SELECT name FROM parties WHERE id = NEW.party_id))
            WHERE voucher_no = NEW.voucher_no AND account_id = v_party_account_id;
        END IF;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sale_ledger_strict
AFTER INSERT OR UPDATE OR DELETE ON public.sales
FOR EACH ROW EXECUTE FUNCTION public.proc_sale_ledger_strict();


-- 3. SMART PURCHASES TRIGGER (Replacing proc_purchase_ledger_strict or sync_purchase_v11)
DROP TRIGGER IF EXISTS trg_purchase_ledger_strict ON public.purchases;
DROP TRIGGER IF EXISTS sync_purchase_v11_trigger ON public.purchases;

CREATE OR REPLACE FUNCTION public.proc_purchase_ledger_strict()
RETURNS TRIGGER AS $$
DECLARE
    v_party_account_id UUID;
    v_purchase_account_id UUID;
    v_party_name TEXT;
    v_delta NUMERIC;
BEGIN
    SELECT id INTO v_party_account_id FROM accounts WHERE code = '1100';
    SELECT id INTO v_purchase_account_id FROM accounts WHERE code = '5000';
    IF v_purchase_account_id IS NULL THEN
        SELECT id INTO v_purchase_account_id FROM accounts WHERE code = '1200';
    END IF;
    
    IF TG_OP = 'INSERT' THEN
        SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;

        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
        VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_purchase_account_id, NULL, NEW.total_amount, 0, 'Purchase from ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

        INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
        VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_party_account_id, NEW.party_id, 0, NEW.total_amount, 'Credit Purchase - ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

        PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'IN');

        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        -- Strict delete: Must have full quantity to deduct (update_stock_quantity throws if insufficient)
        PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'OUT');
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        -- Smart Edit bypass for stock
        IF NEW.fuel_type_id IS DISTINCT FROM OLD.fuel_type_id THEN
            -- Deduct old, add new
            PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'OUT');
            PERFORM public.update_stock_quantity(NEW.fuel_type_id, NEW.quantity, 'IN');
        ELSIF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
            v_delta := NEW.quantity - OLD.quantity;
            IF v_delta > 0 THEN
                -- Bought more, add to stock
                PERFORM public.update_stock_quantity(NEW.fuel_type_id, v_delta, 'IN');
            ELSIF v_delta < 0 THEN
                -- Bought less, remove from stock (throws if insufficient)
                PERFORM public.update_stock_quantity(NEW.fuel_type_id, abs(v_delta), 'OUT');
            END IF;
        END IF;

        -- Handle Ledger Rebuild
        IF NEW.total_amount IS DISTINCT FROM OLD.total_amount 
           OR NEW.rate_per_unit IS DISTINCT FROM OLD.rate_per_unit
           OR NEW.quantity IS DISTINCT FROM OLD.quantity
           OR NEW.purchase_date IS DISTINCT FROM OLD.purchase_date
           OR NEW.party_id IS DISTINCT FROM OLD.party_id THEN
            
            SELECT name INTO v_party_name FROM parties WHERE id = NEW.party_id;
            
            DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
            VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_purchase_account_id, NULL, NEW.total_amount, 0, 'Purchase from ' || v_party_name, NEW.quantity, NEW.rate_per_unit);

            INSERT INTO ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, quantity, rate)
            VALUES (NEW.voucher_no, 'purchase', NEW.purchase_date, v_party_account_id, NEW.party_id, 0, NEW.total_amount, 'Credit Purchase - ' || v_party_name, NEW.quantity, NEW.rate_per_unit);
        ELSE
            -- Narration only update
            UPDATE public.ledger_entries 
            SET narration = COALESCE(NEW.notes, 'Purchase from ' || (SELECT name FROM parties WHERE id = NEW.party_id))
            WHERE voucher_no = NEW.voucher_no AND account_id = v_purchase_account_id;
        END IF;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_purchase_ledger_strict
AFTER INSERT OR UPDATE OR DELETE ON public.purchases
FOR EACH ROW EXECUTE FUNCTION public.proc_purchase_ledger_strict();


-- 4. UN-BLOCK FRONTEND RPCS
CREATE OR REPLACE FUNCTION public.edit_sale_transaction(
    p_original_voucher_no text,
    p_sale_date date,
    p_party_id uuid,
    p_fuel_type_id uuid,
    p_quantity numeric,
    p_rate_per_unit numeric,
    p_total_amount numeric,
    p_is_credit boolean DEFAULT false,
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.sales
    SET sale_date = p_sale_date,
        party_id = p_party_id,
        fuel_type_id = p_fuel_type_id,
        quantity = p_quantity,
        rate_per_unit = p_rate_per_unit,
        total_amount = p_total_amount,
        is_credit = p_is_credit,
        notes = p_notes
    WHERE voucher_no = p_original_voucher_no;
    
    RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_purchase_transaction(
    p_original_voucher_no text,
    p_purchase_date date,
    p_party_id uuid,
    p_fuel_type_id uuid,
    p_quantity numeric,
    p_rate_per_unit numeric,
    p_total_amount numeric,
    p_is_paid_now boolean DEFAULT false,
    p_payment_method text DEFAULT 'Cash',
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.purchases
    SET purchase_date = p_purchase_date,
        party_id = p_party_id,
        fuel_type_id = p_fuel_type_id,
        quantity = p_quantity,
        rate_per_unit = p_rate_per_unit,
        total_amount = p_total_amount,
        is_paid_now = p_is_paid_now,
        payment_method = p_payment_method,
        notes = p_notes
    WHERE voucher_no = p_original_voucher_no;

    RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_transaction_safely(
    p_voucher_no text,
    p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_deleted_count integer := 0;
BEGIN
    -- Check if it's a sale
    IF EXISTS (SELECT 1 FROM public.sales WHERE voucher_no = p_voucher_no) THEN
        DELETE FROM public.sales WHERE voucher_no = p_voucher_no;
        RETURN jsonb_build_object('success', true);
    END IF;

    -- Check if it's a purchase
    IF EXISTS (SELECT 1 FROM public.purchases WHERE voucher_no = p_voucher_no) THEN
        DELETE FROM public.purchases WHERE voucher_no = p_voucher_no;
        RETURN jsonb_build_object('success', true);
    END IF;

    -- Check if it's a payment
    IF to_regclass('public.payments') IS NOT NULL THEN
        EXECUTE 'DELETE FROM public.payments WHERE voucher_no = $1' USING p_voucher_no;
        GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
        IF v_deleted_count > 0 THEN
            RETURN jsonb_build_object('success', true);
        END IF;
    END IF;

    -- Fallback/Ledger-only deletion (e.g., general transactions, shrinkage, expense, etc.)
    DELETE FROM public.ledger_entries WHERE voucher_no = p_voucher_no;
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    IF v_deleted_count > 0 THEN
        RETURN jsonb_build_object('success', true);
    END IF;

    RETURN jsonb_build_object('success', false, 'error', 'Transaction not found.');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.reverse_transaction_safely(
    p_voucher_no text,
    p_reason text DEFAULT 'Reversed for edit'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.delete_transaction_safely(p_voucher_no, p_reason);
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_transaction_safely(
    p_voucher_no text,
    p_reason text DEFAULT 'Cancelled from UI'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.delete_transaction_safely(p_voucher_no, p_reason);
END;
$$;

CREATE OR REPLACE FUNCTION public.reverse_transaction(
    p_voucher_no text,
    p_reason text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.delete_transaction_safely(p_voucher_no, p_reason)::json;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_transaction_safely(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reverse_transaction_safely(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_transaction_safely(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reverse_transaction(text, text) TO authenticated;

-- Reload schema cache for PostgREST
NOTIFY pgrst, 'reload schema';

COMMIT;

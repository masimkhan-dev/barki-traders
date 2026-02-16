-- =================================================================
-- 🔧 PHASE 2: PRODUCTION HARDENING
-- Trigger Consolidation + Health Check Engine + Stock Guard
-- Project: Naveed Musazai — Fuel Trust Ledger
-- Date: 2026-02-16
--
-- ⚠️  WHAT THIS DOES:
-- 1. Consolidates trigger functions (ensures the HARDENED version is active)
-- 2. Creates an RPC-callable health check function (replace manual SQL)
-- 3. Adds a reconciliation mark function (if missing)
-- 4. Diagnoses current trigger state BEFORE changing anything
--
-- ✅ SAFE:
-- - CREATE OR REPLACE won't break existing data
-- - Triggers fire on future operations only
-- - Health check is READ-ONLY (SELECT only)
-- =================================================================

BEGIN;

-- =================================================================
-- STEP 0: DIAGNOSE CURRENT STATE
-- Run this SELECT first to see what triggers are currently active.
-- This does NOT change anything.
-- =================================================================

-- Check which triggers exist on sales, purchases, ledger_entries
SELECT
  event_object_table AS table_name,
  trigger_name,
  action_timing,
  event_manipulation,
  action_statement
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('sales', 'purchases', 'ledger_entries', 'payments')
ORDER BY event_object_table, trigger_name;


-- =================================================================
-- STEP 1: CONSOLIDATED SALE TRIGGER (Hardened Version)
-- Source: final_gold_repair.sql (the strongest version)
--
-- Improvements over baseline:
-- ✅ Stock-below-zero GUARD at DB level
-- ✅ Positive quantity enforcement
-- ✅ FOR UPDATE lock (race condition prevention)
-- ✅ Cash vs Credit sale distinction
-- ✅ Audit log entry on reversal
-- ✅ created_by propagation to ledger entries
-- =================================================================

CREATE OR REPLACE FUNCTION public.sync_sale_v11()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_inv_id UUID; v_cogs_id UUID; v_rev_id UUID; v_ar_id UUID; v_cash_id UUID;
    v_cur_qty NUMERIC; v_cost NUMERIC; v_dr_id UUID; v_nar TEXT;
BEGIN
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_cogs_id FROM accounts WHERE slug = 'cogs';
    SELECT id INTO v_rev_id FROM accounts WHERE slug = 'sales_revenue';
    SELECT id INTO v_ar_id FROM accounts WHERE slug = 'ar';
    SELECT id INTO v_cash_id FROM accounts WHERE slug = 'cash';

    -- [A] REVERSAL (Delete/Update: undo old entry)
    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        -- Restore inventory
        UPDATE public.inventory SET quantity = quantity + OLD.quantity
        WHERE fuel_type_id = OLD.fuel_type_id;

        -- Remove old ledger entries
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;

        -- Audit trail
        BEGIN
            INSERT INTO audit_logs (table_name, record_id, action, old_data, changed_by)
            VALUES ('sales', OLD.id, TG_OP, row_to_json(OLD), auth.uid());
        EXCEPTION WHEN OTHERS THEN
            -- audit_logs insert failure should NOT block the transaction
            NULL;
        END;
    END IF;

    -- [B] APPLICATION (Insert/Update: apply new entry)
    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        -- Guard: quantity must be positive
        IF NEW.quantity <= 0 THEN
            RAISE EXCEPTION 'SALE ERROR: Quantity must be positive. Got: %', NEW.quantity;
        END IF;

        -- Guard: check stock sufficiency (WITH LOCK)
        SELECT quantity, avg_cost INTO v_cur_qty, v_cost
        FROM public.inventory
        WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

        IF COALESCE(v_cur_qty, 0) < NEW.quantity THEN
            RAISE EXCEPTION 'STOCK OUT: Only % L available. Requested: % L.', COALESCE(v_cur_qty, 0), NEW.quantity;
        END IF;

        -- Determine debit account (Cash sale → Cash, Credit sale → AR)
        IF NEW.is_credit THEN
            v_dr_id := v_ar_id;
            v_nar := 'Fuel Sale (Credit)';
        ELSE
            v_dr_id := v_cash_id;
            v_nar := 'Fuel Sale (Cash)';
        END IF;

        -- Deduct inventory
        UPDATE public.inventory SET quantity = quantity - NEW.quantity
        WHERE fuel_type_id = NEW.fuel_type_id;

        -- Post 4-leg ledger entry (Dr Cash/AR, Cr Revenue, Dr COGS, Cr Inventory)
        INSERT INTO public.ledger_entries
            (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES
            (NEW.voucher_no, 'sale', NEW.sale_date, v_dr_id,
             CASE WHEN NEW.is_credit THEN NEW.party_id ELSE NULL END,
             NEW.total_amount, 0, v_nar, NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_rev_id, NULL,
             0, NEW.total_amount, 'Sales Revenue', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_cogs_id, NULL,
             (NEW.quantity * v_cost), 0, 'COGS Adjustment', NEW.created_by),
            (NEW.voucher_no, 'sale', NEW.sale_date, v_inv_id, NULL,
             0, (NEW.quantity * v_cost), 'Inventory Reduction', NEW.created_by);

        RETURN NEW;
    END IF;

    IF (TG_OP = 'DELETE') THEN RETURN OLD; END IF;
    RETURN NULL;
END; $$;


-- =================================================================
-- STEP 2: CONSOLIDATED PURCHASE TRIGGER (Hardened Version)
--
-- Improvements over baseline:
-- ✅ FOR UPDATE lock (race condition prevention)
-- ✅ Stock reduction guard (can't delete purchase if stock already sold)
-- ✅ Positive quantity enforcement
-- ✅ Proper COALESCE for null protection
-- ✅ Audit log entry
-- ✅ created_by propagation
-- =================================================================

CREATE OR REPLACE FUNCTION public.sync_purchase_v11()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_inv_id UUID; v_ap_id UUID;
    v_qty NUMERIC; v_cost NUMERIC;
BEGIN
    SELECT id INTO v_inv_id FROM accounts WHERE slug = 'inventory';
    SELECT id INTO v_ap_id FROM accounts WHERE slug = 'ap';

    -- [A] REVERSAL (Delete/Update: undo old entry)
    IF (TG_OP IN ('DELETE', 'UPDATE')) THEN
        -- Lock and check stock
        SELECT quantity, avg_cost INTO v_qty, v_cost
        FROM public.inventory
        WHERE fuel_type_id = OLD.fuel_type_id FOR UPDATE;

        IF (COALESCE(v_qty, 0) - OLD.quantity + COALESCE(NEW.quantity, 0)) < 0 THEN
            RAISE EXCEPTION 'STOCK INTEGRITY ERROR: Cannot reverse purchase. Current stock (%) would go below zero after removing % units.', v_qty, OLD.quantity;
        END IF;

        -- Audit trail
        BEGIN
            INSERT INTO audit_logs (table_name, record_id, action, old_data, changed_by)
            VALUES ('purchases', OLD.id, TG_OP, row_to_json(OLD), auth.uid());
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;

        -- Reduce inventory
        UPDATE public.inventory SET quantity = quantity - OLD.quantity
        WHERE fuel_type_id = OLD.fuel_type_id;

        -- Remove old ledger entries
        DELETE FROM public.ledger_entries WHERE voucher_no = OLD.voucher_no;
    END IF;

    -- [B] APPLICATION (Insert/Update: apply new entry)
    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        -- Guard: quantity must be positive
        IF NEW.quantity <= 0 THEN
            RAISE EXCEPTION 'PURCHASE ERROR: Quantity must be positive. Got: %', NEW.quantity;
        END IF;

        -- Recalculate weighted average cost
        SELECT quantity, avg_cost INTO v_qty, v_cost
        FROM public.inventory
        WHERE fuel_type_id = NEW.fuel_type_id FOR UPDATE;

        IF (COALESCE(v_qty, 0) + NEW.quantity) > 0 THEN
            v_cost := ((COALESCE(v_qty, 0) * COALESCE(v_cost, 0)) + (NEW.quantity * NEW.rate_per_unit))
                      / (COALESCE(v_qty, 0) + NEW.quantity);
        ELSE
            v_cost := NEW.rate_per_unit;
        END IF;

        -- Update inventory
        UPDATE public.inventory SET quantity = quantity + NEW.quantity, avg_cost = v_cost
        WHERE fuel_type_id = NEW.fuel_type_id;

        -- Post 2-leg ledger entry (Dr Inventory, Cr AP)
        INSERT INTO public.ledger_entries
            (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
        VALUES
            (NEW.voucher_no, 'purchase', NEW.purchase_date, v_inv_id, NULL,
             NEW.total_amount, 0, 'Inventory Purchase', NEW.created_by),
            (NEW.voucher_no, 'purchase', NEW.purchase_date, v_ap_id, NEW.party_id,
             0, NEW.total_amount, 'Accounts Payable', NEW.created_by);

        RETURN NEW;
    END IF;

    IF (TG_OP = 'DELETE') THEN RETURN OLD; END IF;
    RETURN NULL;
END; $$;


-- =================================================================
-- STEP 3: AUTOMATED HEALTH CHECK (callable via RPC)
--
-- Usage from frontend:
--   const { data } = await supabase.rpc('run_system_health_check');
--
-- Returns a JSON object with:
-- - ledger_balance: Sum(Dr) - Sum(Cr) — MUST be 0
-- - unbalanced_vouchers: Vouchers where Dr ≠ Cr
-- - negative_stock: Fuel types with stock below 0
-- - orphan_ledger_entries: Entries with no matching sale/purchase/payment
-- - party_balance_drift: Parties where current_balance doesn't match ledger
-- =================================================================

CREATE OR REPLACE FUNCTION public.run_system_health_check()
RETURNS JSON AS $$
DECLARE
    v_ledger_balance NUMERIC;
    v_unbalanced_count INT;
    v_negative_stock_count INT;
    v_orphan_count INT;
    v_drift_count INT;
    v_result JSON;
BEGIN
    -- 1. Global Ledger Balance (MUST be 0)
    SELECT COALESCE(SUM(debit_amount) - SUM(credit_amount), 0)
    INTO v_ledger_balance
    FROM public.ledger_entries
    WHERE (is_reversed = false OR is_reversed IS NULL);

    -- 2. Unbalanced Vouchers (Dr ≠ Cr within same voucher)
    SELECT COUNT(*) INTO v_unbalanced_count
    FROM (
        SELECT voucher_no
        FROM public.ledger_entries
        WHERE (is_reversed = false OR is_reversed IS NULL)
        GROUP BY voucher_no
        HAVING ABS(SUM(debit_amount) - SUM(credit_amount)) > 0.01
    ) sub;

    -- 3. Negative Stock Check
    SELECT COUNT(*) INTO v_negative_stock_count
    FROM public.inventory
    WHERE quantity < 0;

    -- 4. Orphan Ledger Entries (vouchers with no parent transaction)
    SELECT COUNT(DISTINCT le.voucher_no) INTO v_orphan_count
    FROM public.ledger_entries le
    WHERE le.voucher_type IN ('sale', 'purchase')
      AND (le.is_reversed = false OR le.is_reversed IS NULL)
      AND NOT EXISTS (SELECT 1 FROM sales s WHERE s.voucher_no = le.voucher_no)
      AND NOT EXISTS (SELECT 1 FROM purchases p WHERE p.voucher_no = le.voucher_no);

    -- 5. Party Balance Drift (current_balance vs ledger sum)
    SELECT COUNT(*) INTO v_drift_count
    FROM (
        SELECT
            p.id,
            p.current_balance as stored,
            COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0) as calculated
        FROM public.parties p
        LEFT JOIN public.ledger_entries le ON le.party_id = p.id
            AND (le.is_reversed = false OR le.is_reversed IS NULL)
        GROUP BY p.id, p.current_balance, p.opening_balance
        HAVING ABS(p.current_balance - (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0))) > 0.01
    ) drifted;

    -- Build result
    v_result := json_build_object(
        'timestamp', NOW(),
        'overall_status', CASE
            WHEN v_ledger_balance != 0 OR v_unbalanced_count > 0 OR v_negative_stock_count > 0 THEN 'CRITICAL'
            WHEN v_orphan_count > 0 OR v_drift_count > 0 THEN 'WARNING'
            ELSE 'HEALTHY'
        END,
        'checks', json_build_object(
            'ledger_balance', json_build_object(
                'value', v_ledger_balance,
                'status', CASE WHEN v_ledger_balance = 0 THEN 'PASS' ELSE 'FAIL' END,
                'message', CASE WHEN v_ledger_balance = 0 THEN 'Ledger is balanced (Dr = Cr)' ELSE 'CRITICAL: Ledger imbalance detected: ' || v_ledger_balance END
            ),
            'unbalanced_vouchers', json_build_object(
                'count', v_unbalanced_count,
                'status', CASE WHEN v_unbalanced_count = 0 THEN 'PASS' ELSE 'FAIL' END,
                'message', CASE WHEN v_unbalanced_count = 0 THEN 'All vouchers are balanced' ELSE v_unbalanced_count || ' unbalanced voucher(s) found' END
            ),
            'negative_stock', json_build_object(
                'count', v_negative_stock_count,
                'status', CASE WHEN v_negative_stock_count = 0 THEN 'PASS' ELSE 'FAIL' END,
                'message', CASE WHEN v_negative_stock_count = 0 THEN 'No negative stock' ELSE v_negative_stock_count || ' fuel type(s) with negative stock' END
            ),
            'orphan_entries', json_build_object(
                'count', v_orphan_count,
                'status', CASE WHEN v_orphan_count = 0 THEN 'PASS' ELSE 'WARNING' END,
                'message', CASE WHEN v_orphan_count = 0 THEN 'No orphan entries' ELSE v_orphan_count || ' orphan voucher(s) found' END
            ),
            'party_balance_drift', json_build_object(
                'count', v_drift_count,
                'status', CASE WHEN v_drift_count = 0 THEN 'PASS' ELSE 'WARNING' END,
                'message', CASE WHEN v_drift_count = 0 THEN 'All party balances match ledger' ELSE v_drift_count || ' party balance(s) out of sync' END
            )
        )
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


-- =================================================================
-- STEP 4: RECONCILIATION FUNCTION (if missing)
-- Used by Roznamcha verify button
-- =================================================================

CREATE OR REPLACE FUNCTION public.mark_as_reconciled(p_voucher_no TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE public.ledger_entries
    SET reconciliation_status = true,
        reconciled_at = NOW()
    WHERE voucher_no = p_voucher_no;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- =================================================================
-- STEP 5: VERIFICATION
-- =================================================================

-- 5.1 Run the health check to verify current state
SELECT public.run_system_health_check();

-- 5.2 Verify triggers are correctly attached
SELECT
  event_object_table AS table_name,
  trigger_name,
  action_statement
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN ('sales', 'purchases', 'ledger_entries')
ORDER BY event_object_table;

COMMIT;

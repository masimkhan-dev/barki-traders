-- PHASE 25: THE FINAL AUDIT CLEARANCE (SEV-0 REPAIR)
-- MISSION: ELIMINATE RACE CONDITIONS, FIX RLS BYPASSES, AND CLEAN UP DUPLICATE TRIGGERS
-- ---------------------------------------------------------------------------

BEGIN;

-- 1. FIX FIN-001: SERIALIZED LEDGER HASHING (Race Condition Prevention)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ledger_control (
    id INT PRIMARY KEY DEFAULT 1,
    last_hash TEXT NOT NULL,
    CONSTRAINT single_row_check CHECK (id = 1)
);

-- Initialize if empty
INSERT INTO public.ledger_control (id, last_hash) 
VALUES (1, 'GENESIS') 
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.chain_ledger_entries()
RETURNS TRIGGER AS $$
DECLARE
    v_prev_hash TEXT;
BEGIN
    -- LOCK the control row to ensure absolute linear serialization of the hash chain
    SELECT last_hash INTO v_prev_hash FROM public.ledger_control WHERE id = 1 FOR UPDATE;
    
    NEW.prev_entry_hash := v_prev_hash;
    NEW.entry_hash := md5(
        COALESCE(NEW.prev_entry_hash, 'GENESIS') || '|' ||
        NEW.voucher_no || '|' ||
        NEW.posting_date::TEXT || '|' ||
        NEW.account_id::TEXT || '|' ||
        NEW.debit_amount::TEXT || '|' ||
        NEW.credit_amount::TEXT || '|' ||
        COALESCE(NEW.party_id::TEXT, 'NONE')
    );
    
    -- Update the control row for the next entry
    UPDATE public.ledger_control SET last_hash = NEW.entry_hash WHERE id = 1;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Re-bind trigger (it was already created in Phase 22, but we updated the function)
DROP TRIGGER IF EXISTS trg_chain_ledger ON ledger_entries;
CREATE TRIGGER trg_chain_ledger
    BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION chain_ledger_entries();


-- 2. FIX FIN-003: CONSOLIDATED BALANCE SYNC (Eliminate Duplicates)
-- ---------------------------------------------------------------------------
-- Drop the duplicate trigger from 20260120100000
DROP TRIGGER IF EXISTS trg_update_party_balance ON public.ledger_entries;

-- Harden the remaining sync_party_balance_strict to be more robust
CREATE OR REPLACE FUNCTION public.sync_party_balance_strict()
RETURNS TRIGGER AS $$
BEGIN
    -- Only update if party_id changed or is new
    IF (TG_OP = 'INSERT') OR 
       (TG_OP = 'UPDATE' AND (OLD.party_id IS DISTINCT FROM NEW.party_id OR OLD.debit_amount IS DISTINCT FROM NEW.debit_amount OR OLD.credit_amount IS DISTINCT FROM NEW.credit_amount)) THEN
        
        IF NEW.party_id IS NOT NULL THEN
            UPDATE parties 
            SET current_balance = (
                SELECT COALESCE(SUM(debit_amount - credit_amount), 0) 
                FROM ledger_entries 
                WHERE party_id = NEW.party_id AND is_reversed = false
            ) 
            WHERE id = NEW.party_id;
        END IF;

        IF TG_OP = 'UPDATE' AND OLD.party_id IS NOT NULL AND OLD.party_id != NEW.party_id THEN
             UPDATE parties SET current_balance = (
                SELECT COALESCE(SUM(debit_amount - credit_amount), 0) 
                FROM ledger_entries WHERE party_id = OLD.party_id AND is_reversed = false
            ) WHERE id = OLD.party_id;
        END IF;
    END IF;
    
    IF (TG_OP = 'DELETE') THEN
        IF OLD.party_id IS NOT NULL THEN
            UPDATE parties 
            SET current_balance = (
                SELECT COALESCE(SUM(debit_amount - credit_amount), 0) 
                FROM ledger_entries 
                WHERE party_id = OLD.party_id AND is_reversed = false
            ) 
            WHERE id = OLD.party_id;
        END IF;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;


-- 3. FIX SEC-001: ENABLE MISSING RLS
-- ---------------------------------------------------------------------------
-- Ensure the integrity table exists (might be missing if early migrations were skipped)
CREATE TABLE IF NOT EXISTS public.ledger_integrity_hashes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_date DATE NOT NULL UNIQUE,
    entry_count INTEGER NOT NULL,
    ledger_hash TEXT NOT NULL,
    prev_hash TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    verified_at TIMESTAMPTZ
);

ALTER TABLE public.fiscal_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_integrity_hashes ENABLE ROW LEVEL SECURITY;

-- Apply basic policies to Hash Table
DROP POLICY IF EXISTS "Hashes View" ON ledger_integrity_hashes;
CREATE POLICY "Hashes View" ON ledger_integrity_hashes FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "Hashes Admin" ON ledger_integrity_hashes;
CREATE POLICY "Hashes Admin" ON ledger_integrity_hashes FOR ALL TO authenticated USING (is_admin());


-- 4. FIX FIN-002: RESOLVE TRIGGER CONFLICTS
-- ---------------------------------------------------------------------------
-- We keep the immutability trigger. Users should not be deleting Sales/Purchases/Payments.
-- However, if they DO delete a Sale record (not recommended), we must ensure the ledger entries 
-- can be deleted by the trigger. 
-- Fix: We add a 'session variable' check to the immutability trigger to allow system-level deletes.

CREATE OR REPLACE FUNCTION prevent_ledger_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Allow deletion IFF explicitly authorized by a local session variable (System Override)
    IF current_setting('ledger.allow_mutation', true) = 'on' THEN
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'COMPLIANCE ERROR: Ledger entries are IMMUTABLE. Post a reversal instead.';
    END IF;
    RETURN NEW;
END;
$$;

-- Update the Cascade Delete functions to use the override
CREATE OR REPLACE FUNCTION public.proc_cascade_delete_ledger()
RETURNS TRIGGER AS $$
BEGIN
    -- 1. Set override
    PERFORM set_config('ledger.allow_mutation', 'on', true);

    -- 2. Reverse Stock
    IF TG_TABLE_NAME = 'sales' THEN
        PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'IN');
    ELSIF TG_TABLE_NAME = 'purchases' THEN
        PERFORM public.update_stock_quantity(OLD.fuel_type_id, OLD.quantity, 'OUT');
    END IF;

    -- 3. Delete Ledger Entries (Now allowed due to session config)
    DELETE FROM ledger_entries WHERE voucher_no = OLD.voucher_no;

    -- 4. Reset override
    PERFORM set_config('ledger.allow_mutation', 'off', true);

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;


-- 5. PERFORMANCE: ADD MISSING INDEXES
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_ledger_is_reversed ON ledger_entries(is_reversed) WHERE is_reversed = false;


COMMIT;

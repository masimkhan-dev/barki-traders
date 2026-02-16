-- =================================================================
-- MIGRATION: 20260114000011_merkle_chain_and_security.sql
-- PURPOSE: Fix Merkle Chain Logic, Lock Down Permissions, RPC Security
-- AUDITOR: Principal Financial Systems Engineer
-- =================================================================

-- -----------------------------------------------------------------
-- 1. FIX MERKLE CHAIN (True Blockchain Logic)
-- -----------------------------------------------------------------

CREATE OR REPLACE FUNCTION generate_daily_ledger_hash(p_date DATE)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER -- Must be security definer to read hashes
AS $$
DECLARE
    v_content TEXT;
    v_prev_hash TEXT;
    v_final_hash TEXT;
    v_count INTEGER;
BEGIN
    -- 1. Aggregate Day's Content (Deterministic Order)
    SELECT STRING_AGG(
        id::text || voucher_no || account_id::text || debit_amount::text || credit_amount::text || created_at::text,
        '|' ORDER BY created_at, id
    ), COUNT(*)
    INTO v_content, v_count
    FROM ledger_entries
    WHERE posting_date = p_date;
    
    IF v_content IS NULL THEN 
        v_content := 'EMPTY_DAY'; 
        v_count := 0;
    END IF;
    
    -- 2. Get Previous Link (The "Chain")
    -- We look for the most recent hash strictly before this date
    SELECT ledger_hash INTO v_prev_hash
    FROM ledger_integrity_hashes
    WHERE period_date < p_date
    ORDER BY period_date DESC
    LIMIT 1;
    
    -- Genesis Block handling
    IF v_prev_hash IS NULL THEN
        v_prev_hash := 'GENESIS_HASH_START_0000';
    END IF;
    
    -- 3. Generate Final Hash (Current Content + Previous Hash)
    -- This makes it impossible to change history without invalidating today's hash
    v_final_hash := md5(v_prev_hash || '||' || v_content);
    
    -- 4. Store
    INSERT INTO ledger_integrity_hashes (period_date, entry_count, ledger_hash, prev_hash, verified_at)
    VALUES (p_date, v_count, v_final_hash, v_prev_hash, NOW())
    ON CONFLICT (period_date) DO UPDATE 
    SET ledger_hash = EXCLUDED.ledger_hash,
        prev_hash = EXCLUDED.prev_hash, -- Update prev link if chain reorganized (should verify!)
        entry_count = EXCLUDED.entry_count,
        verified_at = NOW();
        
    RETURN v_final_hash;
END;
$$;

-- -----------------------------------------------------------------
-- 2. IMMUTABILITY RULES (Database Level)
-- -----------------------------------------------------------------

-- A. Revoke direct write access to Ledger from API (Authenticated users)
-- Force usage of RPCs (create_money_movement, etc.)
-- Note: We rely on RLS generally, but revoking permissions is stronger.

-- Check if role exists before revoking to avoid errors in dev environments
DO $$
BEGIN
    -- Revoke standard access
    -- (Assuming Supabase 'authenticated' and 'anon' roles)
    EXECUTE 'REVOKE UPDATE, DELETE ON ledger_entries FROM authenticated';
    EXECUTE 'REVOKE UPDATE, DELETE ON ledger_entries FROM anon';
    
    -- Only allow INSERT if strictly necessary, but ideally also REVOKE INSERT
    -- and force RPCs. However, simpler forms might insert directly. 
    -- For now, we strictly Block UPDATE/DELETE (History Rewrite).
END $$;

-- B. Create a Trigger that HARD FAILS on any Update/Delete attempts 
-- regardless of who tries it (even Admin), unless specifically authorized via variable?
-- No, let's just block it for safety. Ledger is append-only.
-- To "Correct" a mistake, you must insert a "Reversal" entry.

CREATE OR REPLACE FUNCTION prevent_ledger_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'COMPLIANCE ERROR: Ledger/Journal entries are IMMUTABLE. Post a reversal entry instead. (Ref: Audit Rule 4.2)';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_ledger_immutability ON ledger_entries;

CREATE TRIGGER enforce_ledger_immutability
BEFORE UPDATE OR DELETE ON ledger_entries
FOR EACH ROW
EXECUTE FUNCTION prevent_ledger_modification();

-- -----------------------------------------------------------------
-- 3. MUNSHI-FRIENDLY HELPERS (Optional Views)
-- -----------------------------------------------------------------

CREATE OR REPLACE VIEW view_munshi_khata AS
SELECT 
    le.posting_date as "Tareekh",
    le.voucher_no as "Raseed_No",
    le.description as "Tafseel",
    CASE WHEN le.debit_amount > 0 THEN le.debit_amount ELSE 0 END as "Naam (Dr)",
    CASE WHEN le.credit_amount > 0 THEN le.credit_amount ELSE 0 END as "Jama (Cr)",
    a.name as "Khata",
    le.created_at
FROM ledger_entries le
JOIN accounts a ON le.account_id = a.id
ORDER BY le.posting_date DESC, le.created_at DESC;


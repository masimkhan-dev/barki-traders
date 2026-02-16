-- FDMS ULTIMATE REPORTING & GHOST CLEANUP (V37)
-- Objective: Kill the 'Opening Investment' ghost and fix get_trial_balance_v2

BEGIN;

-- Safety bypass
SET session_replication_role = 'replica';

DO $$
DECLARE
    v_ghost_inv_id UUID;
    v_cap_id UUID;
    v_ghost_bal NUMERIC;
BEGIN
    -- 1. Get IDs
    -- We look for 'Opening Investment' specifically
    SELECT id INTO v_ghost_inv_id FROM public.accounts WHERE name = 'Opening Investment' LIMIT 1;
    SELECT id INTO v_cap_id FROM public.accounts WHERE code = '3010' LIMIT 1;

    -- 2. Zero out Opening Investment if it exists
    IF v_ghost_inv_id IS NOT NULL THEN
        SELECT COALESCE(SUM(credit_amount - debit_amount), 0) INTO v_ghost_bal 
        FROM ledger_entries WHERE account_id = v_ghost_inv_id AND (is_reversed IS NULL OR is_reversed = false);

        IF v_ghost_bal != 0 THEN
            INSERT INTO public.ledger_entries (voucher_no, voucher_type, account_id, posting_date, debit_amount, credit_amount, narration)
            VALUES ('GHOST-KILL-INV', 'opening_balance', v_ghost_inv_id, CURRENT_DATE, v_ghost_bal, 0, 'Audit: Clearing duplicate Opening Investment artifact');
            
            INSERT INTO public.ledger_entries (voucher_no, voucher_type, account_id, posting_date, debit_amount, credit_amount, narration)
            VALUES ('GHOST-KILL-INV', 'opening_balance', v_cap_id, CURRENT_DATE, 0, v_ghost_bal, 'Audit: Settling ghost investment into Capital');
        END IF;
    END IF;

END $$;

-- 3. Redeploy the frontend-compatible get_trial_balance_v2
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
    closing_balance NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    WITH account_activity AS (
        SELECT 
            le.account_id,
            -- Sum everything before start date for opening
            SUM(CASE WHEN le.posting_date < COALESCE(p_start_date, '1900-01-01'::DATE) THEN (le.debit_amount - le.credit_amount) ELSE 0 END) as opening,
            -- Sum debits/credits within range for activity
            SUM(CASE WHEN le.posting_date >= COALESCE(p_start_date, '1900-01-01'::DATE) AND le.posting_date <= COALESCE(p_end_date, '2100-01-01'::DATE) THEN le.debit_amount ELSE 0 END) as dr_activity,
            SUM(CASE WHEN le.posting_date >= COALESCE(p_start_date, '1900-01-01'::DATE) AND le.posting_date <= COALESCE(p_end_date, '2100-01-01'::DATE) THEN le.credit_amount ELSE 0 END) as cr_activity
        FROM public.ledger_entries le
        WHERE (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY le.account_id
    )
    SELECT 
        a.code::TEXT,
        a.name::TEXT,
        a.account_type::TEXT,
        opening::NUMERIC as opening_balance,
        dr_activity::NUMERIC as debit_total,
        cr_activity::NUMERIC as credit_total,
        -- Final closing balance (Net)
        (opening + dr_activity - cr_activity)::NUMERIC as closing_balance
    FROM account_activity aa
    JOIN public.accounts a ON a.id = aa.account_id
    WHERE (dr_activity != 0 OR cr_activity != 0 OR opening != 0)
      AND a.code NOT IN ('3950', '3999') -- Exclude internal bridges
      AND a.name != 'Opening Investment' -- Exclude the ghost line specifically
    ORDER BY a.code;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

SET session_replication_role = 'origin';
COMMIT;

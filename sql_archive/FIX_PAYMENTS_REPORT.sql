-- =================================================================
-- ENHANCED BUSINESS REPORT: FROM/TO MONEY MOVEMENT
-- Date: 2026-01-31
-- Purpose: Redefines the Payment Report to show clearly where money 
--          came FROM and where it went TO (Audit Trail style).
-- =================================================================

BEGIN;

-- 1. CLEANUP PREVIOUS VERSIONS
DROP FUNCTION IF EXISTS public.get_payments_report(DATE, DATE, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.get_payments_report(DATE, DATE) CASCADE;

-- 2. CREATE ENHANCED AUDIT-GRADE PAYMENTS REPORT
CREATE OR REPLACE FUNCTION public.get_payments_report(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    posting_date DATE,
    voucher_no TEXT,
    voucher_type TEXT,
    from_name TEXT,
    to_name TEXT,
    amount NUMERIC,
    narration TEXT
) 
LANGUAGE plpgsql 
STABLE 
AS $$
BEGIN
    RETURN QUERY
    WITH voucher_pairs AS (
        -- Group ledger entries by voucher to find both sides
        SELECT 
            le.voucher_no,
            le.posting_date,
            le.voucher_type,
            le.narration,
            le.created_at,
            -- Identity of the "Giver" (Credit side)
            CASE WHEN le.credit_amount > 0 THEN COALESCE(p.name, a.name) END as giver,
            -- Identity of the "Receiver" (Debit side)
            CASE WHEN le.debit_amount > 0 THEN COALESCE(p.name, a.name) END as receiver,
            -- The money amount
            GREATEST(le.debit_amount, le.credit_amount) as entry_amount
        FROM public.ledger_entries le
        JOIN public.accounts a ON le.account_id = a.id
        LEFT JOIN public.parties p ON le.party_id = p.id
        WHERE 
            -- We only want payment-related vouchers for this specific report
            le.voucher_type IN ('receipt', 'payment', 'transfer', 'munshi_voucher', 'journal')
            AND (le.is_reversed IS NULL OR le.is_reversed = false)
    )
    SELECT 
        vp.posting_date,
        vp.voucher_no,
        vp.voucher_type,
        -- Collapse the group into one row per voucher
        MAX(vp.giver) FILTER (WHERE vp.giver IS NOT NULL) as from_name,
        MAX(vp.receiver) FILTER (WHERE vp.receiver IS NOT NULL) as to_name,
        MAX(vp.entry_amount) as amount,
        MAX(vp.narration) as narration
    FROM voucher_pairs vp
    WHERE (p_start_date IS NULL OR vp.posting_date >= p_start_date)
      AND vp.posting_date <= p_end_date
    GROUP BY vp.voucher_no, vp.posting_date, vp.voucher_type, vp.created_at
    ORDER BY vp.posting_date DESC, vp.created_at DESC;
END;
$$;

COMMIT;

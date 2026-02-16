-- FIX OPENING BALANCE EQUITY (CORRECT AMOUNT)
-- Purpose: Adjust from Rs 143,980 to Rs 120,980 (reduce by Rs 23,000)

BEGIN;

SET session_replication_role = 'replica';

DO $$
DECLARE
    v_equity_id UUID;
    v_voucher TEXT := 'ADJ-OBE-' || to_char(now(), 'HHMMSS');
BEGIN
    -- Get Opening Balance Equity account
    SELECT id INTO v_equity_id FROM accounts WHERE slug = 'opening-balance-equity';
    
    -- Reduce by Rs 23,000 (Debit Opening Balance Equity)
    INSERT INTO ledger_entries (
        voucher_no, voucher_type, posting_date, account_id,
        debit_amount, credit_amount, narration, created_by
    ) VALUES (
        v_voucher, 'adjustment', '2025-12-31',
        v_equity_id, 23000, 0,
        'Opening Balance Equity Correction - Final Adjustment',
        COALESCE(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid)
    );
    
    RAISE NOTICE 'Opening Balance Equity corrected to Rs 120,980';
END $$;

SET session_replication_role = 'origin';

COMMIT;

-- Verify
SELECT 
    'Opening Balance Equity (Final)' as account,
    COALESCE(SUM(credit_amount - debit_amount), 0) as balance
FROM ledger_entries
WHERE account_id = (SELECT id FROM accounts WHERE slug = 'opening-balance-equity')
  AND (is_reversed IS NULL OR is_reversed = false);

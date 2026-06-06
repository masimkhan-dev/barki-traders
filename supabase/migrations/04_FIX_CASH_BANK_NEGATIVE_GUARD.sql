-- =============================================================================
-- FIX: Cash/Bank negative guard double-counts NEW row
-- =============================================================================
-- Run after 03_ENABLE_VOUCHER_FACTORY_PHASE2.sql.
-- The old AFTER INSERT trigger summed ledger_entries, which already includes
-- NEW, then added NEW again. A transfer from bank could be falsely blocked.
-- =============================================================================

BEGIN;
SET search_path = public;

CREATE OR REPLACE FUNCTION public.check_account_balance_integrity()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_balance NUMERIC;
  v_slug TEXT;
BEGIN
  SELECT slug INTO v_slug
  FROM public.accounts
  WHERE id = NEW.account_id;

  IF v_slug IN ('cash', 'bank') THEN
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0)
    INTO v_balance
    FROM public.ledger_entries
    WHERE account_id = NEW.account_id
      AND (is_reversed = false OR is_reversed IS NULL);

    IF v_balance < -0.01 THEN
      RAISE EXCEPTION 'FINANCIAL BLOCK: Cash/Bank cannot go negative (balance %).', v_balance;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;

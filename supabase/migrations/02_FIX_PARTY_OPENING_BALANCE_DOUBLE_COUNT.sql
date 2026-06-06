-- =============================================================================
-- FIX: Party opening balance double count
-- =============================================================================
-- Run after 01_FRONTEND_ALIGNMENT_NEW_CLIENT.sql.
-- The UI inserts parties with opening_balance and then calls this RPC to post
-- a balanced ledger opening voucher. After posting, the party table opening
-- must be zeroed so statements/trial balance do not count it twice.
-- =============================================================================

BEGIN;
SET search_path = public;

CREATE OR REPLACE FUNCTION public.initialize_party_opening_balance(
  p_party_id UUID,
  p_amount NUMERIC,
  p_date DATE DEFAULT CURRENT_DATE
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ar_id UUID;
  v_ap_id UUID;
  v_capital_id UUID;
  v_party_name TEXT;
  v_voucher TEXT;
BEGIN
  IF COALESCE(p_amount, 0) = 0 THEN
    UPDATE public.parties
    SET current_balance = COALESCE(opening_balance, 0)
    WHERE id = p_party_id;
    RETURN 'SKIP: Zero opening balance';
  END IF;

  SELECT name INTO v_party_name FROM public.parties WHERE id = p_party_id;
  IF v_party_name IS NULL THEN
    RAISE EXCEPTION 'Party not found.';
  END IF;

  SELECT id INTO v_ar_id FROM public.accounts WHERE slug = 'ar';
  SELECT id INTO v_ap_id FROM public.accounts WHERE slug = 'ap';
  SELECT id INTO v_capital_id FROM public.accounts WHERE slug = 'capital';

  IF v_ar_id IS NULL OR v_ap_id IS NULL OR v_capital_id IS NULL THEN
    RAISE EXCEPTION 'Missing control accounts: ar/ap/capital.';
  END IF;

  v_voucher := 'OB-' || upper(substring(regexp_replace(v_party_name, '[^A-Za-z0-9]', '', 'g'), 1, 3)) || '-' || substring(p_party_id::TEXT, 1, 8);

  IF EXISTS (SELECT 1 FROM public.ledger_entries WHERE voucher_no = v_voucher) THEN
    UPDATE public.parties
    SET opening_balance = 0,
        current_balance = COALESCE((
          SELECT SUM(le.debit_amount - le.credit_amount)
          FROM public.ledger_entries le
          WHERE le.party_id = p_party_id
            AND (le.is_reversed = false OR le.is_reversed IS NULL)
        ), 0)
    WHERE id = p_party_id;
    RETURN 'ERROR: Opening balance already posted for this party';
  END IF;

  IF p_amount > 0 THEN
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES
      (v_voucher, 'opening', p_date, v_ar_id, p_party_id, p_amount, 0, 'Opening Balance - ' || v_party_name || ' (Receivable)', auth.uid()),
      (v_voucher, 'opening', p_date, v_capital_id, NULL, 0, p_amount, 'Opening Balance - ' || v_party_name || ' (Contra)', auth.uid());
  ELSE
    INSERT INTO public.ledger_entries (voucher_no, voucher_type, posting_date, account_id, party_id, debit_amount, credit_amount, narration, created_by)
    VALUES
      (v_voucher, 'opening', p_date, v_capital_id, NULL, abs(p_amount), 0, 'Opening Balance - ' || v_party_name || ' (Contra)', auth.uid()),
      (v_voucher, 'opening', p_date, v_ap_id, p_party_id, 0, abs(p_amount), 'Opening Balance - ' || v_party_name || ' (Payable)', auth.uid());
  END IF;

  UPDATE public.parties
  SET opening_balance = 0,
      current_balance = COALESCE((
        SELECT SUM(le.debit_amount - le.credit_amount)
        FROM public.ledger_entries le
        WHERE le.party_id = p_party_id
          AND (le.is_reversed = false OR le.is_reversed IS NULL)
      ), 0)
  WHERE id = p_party_id;

  RETURN 'SUCCESS: Posted voucher ' || v_voucher;
END;
$$;

-- Repair any parties already affected by the old double-count behavior.
UPDATE public.parties p
SET opening_balance = 0,
    current_balance = COALESCE((
      SELECT SUM(le.debit_amount - le.credit_amount)
      FROM public.ledger_entries le
      WHERE le.party_id = p.id
        AND (le.is_reversed = false OR le.is_reversed IS NULL)
    ), 0)
WHERE p.opening_balance <> 0
  AND EXISTS (
    SELECT 1
    FROM public.ledger_entries le
    WHERE le.party_id = p.id
      AND le.voucher_type = 'opening'
      AND le.voucher_no LIKE 'OB-%'
      AND (le.is_reversed = false OR le.is_reversed IS NULL)
  );

NOTIFY pgrst, 'reload schema';
COMMIT;

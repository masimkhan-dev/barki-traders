BEGIN;

ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS quantity NUMERIC DEFAULT 0;
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS rate NUMERIC DEFAULT 0;

-- Reload schema cache for PostgREST
NOTIFY pgrst, 'reload schema';

COMMIT;

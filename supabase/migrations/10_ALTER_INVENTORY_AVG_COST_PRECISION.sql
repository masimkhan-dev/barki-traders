-- Migration 10: Alter inventory.avg_cost precision from NUMERIC(15,2) to NUMERIC(18,6)
-- and inventory_events.avg_cost_after precision from NUMERIC(15,2) to NUMERIC(18,6)
-- so Weighted Average Cost (WAC) does not lose precision over time.

BEGIN;

ALTER TABLE public.inventory ALTER COLUMN avg_cost TYPE NUMERIC(18,6);
ALTER TABLE public.inventory_events ALTER COLUMN avg_cost_after TYPE NUMERIC(18,6);

-- Reload PostgREST schema cache to pick up changed types
NOTIFY pgrst, 'reload schema';

COMMIT;

-- Fix Purchase Trigger Registration
-- This migration ensures the correct purchase trigger is active

-- Drop the old trigger if exists
DROP TRIGGER IF EXISTS trigger_purchase_ledger ON purchases;

-- Re-create the trigger with the updated function (from 20260113000000)
CREATE TRIGGER trigger_purchase_ledger
    AFTER INSERT ON purchases
    FOR EACH ROW
    EXECUTE FUNCTION create_purchase_ledger_entries();

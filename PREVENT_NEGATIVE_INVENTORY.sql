-- =================================================================================
-- ADVANCED INVENTORY MONITOR & VALIDATOR
-- Purpose: Prevents Sales/COGS postings that would drive the Inventory (Control)
--          Account into a negative financial valuation.
-- Method:  Before Insert Trigger on ledger_entries.
-- =================================================================================

-- 1. Create the Validation Function
CREATE OR REPLACE FUNCTION validate_inventory_balance_before_post()
RETURNS TRIGGER AS $$
DECLARE
    v_inventory_acc_id uuid;
    v_current_inventory_balance numeric;
    v_net_entry_impact numeric;
    v_resulting_balance numeric;
BEGIN
    -- Only run this logic if the entry involves the Inventory (Control) Account
    -- First, get the Inventory account ID dynamically
    SELECT id INTO v_inventory_acc_id FROM accounts 
    WHERE slug = 'inventory_control' OR name ILIKE '%Inventory%Control%' LIMIT 1;
    
    IF v_inventory_acc_id IS NULL THEN
        -- If account doesn't exist, just let the insert pass
        RETURN NEW;
    END IF;

    -- Check if the new entry touches the Inventory Account
    IF NEW.account_id = v_inventory_acc_id THEN
        
        -- Calculate the exact impact of this single new row: 
        -- Positive impact = Debit (Adding to Inventory)
        -- Negative impact = Credit (Removing from Inventory)
        v_net_entry_impact := COALESCE(NEW.debit_amount, 0) - COALESCE(NEW.credit_amount, 0);

        -- We only care about checking balances if this is a REDUCTION (Credit > Debit)
        IF v_net_entry_impact < 0 THEN
            
            -- Calculate Current Running Balance for the account (Sum(Debit) - Sum(Credit))
            SELECT COALESCE(SUM(debit_amount) - SUM(credit_amount), 0)
            INTO v_current_inventory_balance
            FROM ledger_entries
            WHERE account_id = v_inventory_acc_id
              AND is_reversed = FALSE;

            -- Calculate what the balance WILL BE if we allow this insert
            v_resulting_balance := v_current_inventory_balance + v_net_entry_impact;

            -- If the resulting financial valuation drops below zero, BLOCK IT!
            IF v_resulting_balance < 0 THEN
                RAISE EXCEPTION 'INVENTORY_VALUATION_ERROR: Cannot post this entry. It would result in a negative financial inventory balance of % PKR. Current Available Value: % PKR. Attempted Reduction: %', 
                    v_resulting_balance, v_current_inventory_balance, ABS(v_net_entry_impact);
            END IF;
        END IF;
    END IF;

    -- If all checks pass, allow the row to be inserted
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. Attach the Function to the ledger_entries Table as a Trigger
DROP TRIGGER IF EXISTS trg_prevent_negative_inventory ON ledger_entries;

CREATE TRIGGER trg_prevent_negative_inventory
BEFORE INSERT OR UPDATE ON ledger_entries
FOR EACH ROW
EXECUTE FUNCTION validate_inventory_balance_before_post();

RAISE NOTICE 'Inventory Control Validator Active. Future negative overdraws blocked.';

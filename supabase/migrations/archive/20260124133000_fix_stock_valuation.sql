-- Phase 11: PRECISION HISTORICAL STOCK VALUATION
-- -----------------------------------------------------------------
-- Fixes valuation mixing bug. It now calculates stock value per fuel type 
-- using (Closing Qty * Weighted Avg Cost) and sums them up.

BEGIN;

CREATE OR REPLACE FUNCTION get_historical_stock_value(p_date DATE)
RETURNS NUMERIC AS $$
DECLARE
    v_total_stock_value NUMERIC := 0;
BEGIN
    -- Calculate valuation for EACH fuel type independently and sum them up
    SELECT COALESCE(SUM(val), 0) INTO v_total_stock_value
    FROM (
        SELECT 
            f.id,
            -- Closing Quantity for this specific fuel type AT the given date
            (COALESCE((SELECT SUM(quantity) FROM purchases WHERE fuel_type_id = f.id AND purchase_date <= p_date), 0) -
             COALESCE((SELECT SUM(quantity) FROM sales WHERE fuel_type_id = f.id AND sale_date <= p_date), 0)) as closing_qty,
            -- Weighted Average Cost for this specific fuel type AT the given date
            COALESCE(
                (SELECT SUM(total_amount) / NULLIF(SUM(quantity), 0) FROM purchases WHERE fuel_type_id = f.id AND purchase_date <= p_date),
                0
            ) as avg_cost
        FROM fuel_types f
    ) stock_calc 
    WHERE closing_qty > 0;

    -- Return the grand total value of all fuel stocks
    RETURN ROUND(v_total_stock_value, 2);
END;
$$ LANGUAGE plpgsql STABLE;

-- Sync Live Inventory Table for current dashboard accuracy
UPDATE public.inventory i
SET 
    quantity = (SELECT COALESCE(SUM(p.quantity), 0) FROM purchases p WHERE p.fuel_type_id = i.fuel_type_id) - 
               (SELECT COALESCE(SUM(s.quantity), 0) FROM sales s WHERE s.fuel_type_id = i.fuel_type_id),
    avg_cost = COALESCE(
        (SELECT SUM(total_amount) / NULLIF(SUM(quantity), 0) FROM purchases WHERE fuel_type_id = i.fuel_type_id),
        0
    ),
    last_updated = now();

COMMIT;

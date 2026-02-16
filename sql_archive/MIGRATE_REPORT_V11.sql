
-- MIGRATE V11 REPORT FUNCTION NAME
-- Purpose: The UI calls 'get_fixed_assets_report_v11', but we created 'get_fixed_assets_report'.
-- We need to create the _v11 alias that points to our fixed logic.

DROP FUNCTION IF EXISTS get_fixed_assets_report_v11();

CREATE OR REPLACE FUNCTION get_fixed_assets_report_v11()
RETURNS TABLE (
    account_name TEXT,
    original_value NUMERIC,
    depreciation NUMERIC,
    net_value NUMERIC
) AS $$
BEGIN
    -- Just call the robust function we already fixed
    RETURN QUERY SELECT * FROM get_fixed_assets_report();
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

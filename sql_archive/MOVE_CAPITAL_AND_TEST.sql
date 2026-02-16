
-- MOVE CAPITAL DATE TO TODAY
-- Purpose: Ensure the capital entry falls within the current reporting period (Feb 2026).

UPDATE ledger_entries 
SET posting_date = '2026-02-05' 
WHERE narration = 'Initial Capital Investment';

-- ALSO VERIFY THE ASSET FUNCTION OUTPUT DIRECTLY
SELECT * FROM get_fixed_assets_report();

-- SAFER DIAGNOSTIC SCRIPT: CHECK SCHEMA
-- Purpose: Find out exactly what columns we have and if functions exist.

-- 1. Check columns in 'accounts' table
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_name = 'accounts' AND table_schema = 'public';

-- 2. Check if the RPC functions exist (simplified check)
SELECT proname, count(*) 
FROM pg_proc 
WHERE proname IN ('get_owner_capital_report', 'get_fixed_assets_report')
GROUP BY proname;

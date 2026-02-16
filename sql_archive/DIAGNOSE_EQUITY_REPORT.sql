
-- DIAGNOSE REPORT LOGIC FAILURE
-- Purpose: Find out why Capital and Fixed Assets are not showing in the final report.

DO $$
DECLARE
    v_capital_acc_ids UUID[];
    v_report_count INT;
    v_capital_entry_count INT;
    v_asset_entry_count INT;
BEGIN
    RAISE NOTICE '===================================================';
    RAISE NOTICE '       DIAGNOSING EQUITY REPORT FAILURE            ';
    RAISE NOTICE '===================================================';

    -- 1. Check Capital Ledger Entries directly
    SELECT count(*) INTO v_capital_entry_count 
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE (a.slug = 'owner-capital' OR a.name ILIKE '%Capital%');
    
    RAISE NOTICE '1. Total Capital Entires in DB: %', v_capital_entry_count;
    
    -- 2. Check "Laptop" Ledger Entries directly
    SELECT count(*) INTO v_asset_entry_count 
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE a.name ILIKE '%laptop%';
    
    RAISE NOTICE '2. Total Laptop Asset Entries in DB: %', v_asset_entry_count;

    RAISE NOTICE '---------------------------------------------------';
    RAISE NOTICE 'TESTING CAPITAL REPORT LOGIC:';
    
    -- 3. Simulate Logic from "get_owner_capital_report"
    SELECT array_agg(id) INTO v_capital_acc_ids FROM public.accounts 
    WHERE account_type = 'equity' 
       OR slug IN ('capital', 'owner-capital', 'drawings') 
       OR name ILIKE '%Capital%' 
       OR name ILIKE '%Drawings%';
       
    RAISE NOTICE '   -> Found Capital Account IDs: %', v_capital_acc_ids;

    SELECT count(*) INTO v_report_count
    FROM public.ledger_entries le
    WHERE le.account_id = ANY(v_capital_acc_ids) 
      AND (le.is_reversed IS NULL OR le.is_reversed = false);
      
    RAISE NOTICE '   -> Report Filter Count (All Dates): %', v_report_count;

    -- 4. Check Date Range Filter (01/31 to 02/28)
    SELECT count(*) INTO v_report_count
    FROM public.ledger_entries le
    WHERE le.account_id = ANY(v_capital_acc_ids) 
      AND le.posting_date >= '2026-01-31' 
      AND le.posting_date <= '2026-02-28';
      
    RAISE NOTICE '   -> Report Filter Count (Current Period Only): %', v_report_count;
    
    RAISE NOTICE '---------------------------------------------------';
    RAISE NOTICE 'TESTING ASSET REPORT LOGIC:';
    
    -- 5. Simulate Logic from FIXED "get_fixed_assets_report"
    SELECT count(*) INTO v_report_count
    FROM public.accounts a
    JOIN public.ledger_entries le ON a.id = le.account_id
    WHERE a.account_type = 'asset' 
      AND (
          a.sub_category IN ('Equipment', 'Vehicle', 'Furniture', 'Machinery', 'Building') 
          OR a.sub_category ILIKE '%Fixed%' 
          OR a.name ILIKE '%Fixed Asset%'
          OR a.name ILIKE '%Furniture%'
          OR a.name ILIKE '%Building%'
          OR a.name ILIKE '%Vehicle%'
          OR a.name ILIKE '%Machinery%' -- This is our fix
      )
      AND a.slug NOT IN ('cash', 'bank', 'inventory', 'cogs', 'sales_revenue', 'accounts_receivable', 'accounts_payable')
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    RAISE NOTICE '   -> Asset Report Logic Count: %', v_report_count;

    RAISE NOTICE '===================================================';
END $$;

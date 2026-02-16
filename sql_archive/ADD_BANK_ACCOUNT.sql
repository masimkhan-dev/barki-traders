-- =================================================================
-- ADD BANK ACCOUNT TO CHART OF ACCOUNTS (Jan 30, 2026)
-- Target: Enable Bank payments for Expenses & Transfers
-- =================================================================

BEGIN;

-- 1. Insert Bank Account if it doesn't exist
DO $$
DECLARE v_asset_root_id UUID;
BEGIN
    SELECT id INTO v_asset_root_id FROM public.accounts WHERE code = '1000';
    
    IF v_asset_root_id IS NOT NULL THEN
        INSERT INTO public.accounts (code, name, account_type, slug, parent_id, is_system, is_active)
        VALUES ('1020', 'Bank Account', 'asset', 'bank', v_asset_root_id, true, true)
        ON CONFLICT (code) DO UPDATE SET name = 'Bank Account', is_active = true;
    END IF;
END $$;

COMMIT;

BEGIN;

RAISE NOTICE '🌱 STARTING VALIDATION SEED (PRODUCTION MODE)...';

-- 1. ENSURE ACCOUNT HEADS EXIST (The "Skeleton")
DO $$
DECLARE
    -- We need IDs to link parents
    v_asset_id UUID;
    v_liab_id UUID;
    v_inc_id UUID;
    v_exp_id UUID;
BEGIN
    -- Asset Root
    INSERT INTO accounts (code, name, type, account_type, slug) 
    VALUES ('1000', 'Assets', 'asset', 'asset', 'assets_root')
    ON CONFLICT (code) DO NOTHING;
    
    -- Liability Root
    INSERT INTO accounts (code, name, type, account_type, slug) 
    VALUES ('2000', 'Liabilities', 'liability', 'liability', 'liabilities_root')
    ON CONFLICT (code) DO NOTHING;

    -- Income Root
    INSERT INTO accounts (code, name, type, account_type, slug) 
    VALUES ('3000', 'Income', 'income', 'income', 'income_root')
    ON CONFLICT (code) DO NOTHING;

    -- Expense Root
    INSERT INTO accounts (code, name, type, account_type, slug) 
    VALUES ('4000', 'Expenses', 'expense', 'expense', 'expense_root')
    ON CONFLICT (code) DO NOTHING;
    
    -- LEAF ACCOUNTS (Critical for Logic)
    -- 1100: AR (Asset)
    INSERT INTO accounts (code, name, type, account_type, slug, parent_id)
    SELECT '1100', 'Accounts Receivable', 'asset', 'asset', 'ar', id FROM accounts WHERE code = '1000'
    ON CONFLICT (code) DO NOTHING;

    -- 1010: Cash (Asset)
    INSERT INTO accounts (code, name, type, account_type, slug, parent_id)
    SELECT '1010', 'Cash on Hand', 'asset', 'asset', 'cash', id FROM accounts WHERE code = '1000'
    ON CONFLICT (code) DO NOTHING;

    -- 2000: Accounts Payable Control (Liability)
    -- Note: This code '2000' is used as Control in RPC, so it must exist as a leaf or handleable node.
    -- If 2000 is root, we might need a specific leaf like 2100.
    -- However, the RPC code explicitly references select where code='2000' for liability control.
    -- So we ensure 2000 exists. If it was inserted above as root, that's fine, but let's check its usage.
    -- In RPC: SELECT id INTO v_payable_control FROM accounts WHERE code = '2000' LIMIT 1;
    -- In Seed above: I made 2000 the root. This is OK for now as long as it exists.
    
    -- 3100: Sales Revenue (Income)
    INSERT INTO accounts (code, name, type, account_type, slug, parent_id)
    SELECT '3100', 'Sales Revenue', 'income', 'income', 'sales_revenue', id FROM accounts WHERE code = '3000'
    ON CONFLICT (code) DO NOTHING;
    
    -- 4100: Cost of Goods Sold (Expense)
    INSERT INTO accounts (code, name, type, account_type, slug, parent_id)
    SELECT '4100', 'Cost of Goods Sold', 'expense', 'expense', 'cogs', id FROM accounts WHERE code = '4000'
    ON CONFLICT (code) DO NOTHING;

END $$;

-- 2. CREATE PARTIES & EXECUTE TRANSACTIONS (The "Events")
DO $$
DECLARE 
    v_cust_id UUID;
    v_supp_id UUID;
    v_rev_acct_id UUID;
    v_cash_acct_id UUID;
    v_exp_acct_id UUID;
    v_result JSON;
BEGIN
    -- A. Create Actors
    INSERT INTO parties (name, type, opening_balance, current_balance, is_active)
    VALUES ('Tester Transport Co.', 'customer', 0, 0, true)
    RETURNING id INTO v_cust_id;
    
    INSERT INTO parties (name, type, opening_balance, current_balance, is_active)
    VALUES ('Refinery Ltd.', 'supplier', 0, 0, true)
    RETURNING id INTO v_supp_id;
    
    RAISE NOTICE 'Created Parties: Customer=%, Supplier=%', v_cust_id, v_supp_id;

    -- Get Account IDs for Transactions
    SELECT id INTO v_rev_acct_id FROM accounts WHERE code = '3100'; -- Sales Revenue
    SELECT id INTO v_cash_acct_id FROM accounts WHERE code = '1010'; -- Cash
    SELECT id INTO v_exp_acct_id FROM accounts WHERE code = '4100'; -- Expenses

    -- B. EVENT 1: Credit Sale (5000)
    -- Customer (Receives Value/Debit) <-- Revenue Account (Gives Value/Credit)
    -- RPC Signature: create_manage_transaction(type, from_type, from_id, to_type, to_id, amount, narration, date)
    -- From: Revenue (Account) -> To: Customer (Party)
    
    SELECT create_manage_transaction(
        'sale',                         -- Transaction Type (Label)
        'account', v_rev_acct_id,       -- FROM: Revenue Account (Credit)
        'customer', v_cust_id,          -- TO: Customer Party (Debit AR)
        5000,                           -- Amount
        'Seed Credit Sale via RPC',     -- Narration
        CURRENT_DATE                    -- Date
    ) INTO v_result;
    
    RAISE NOTICE 'Sale Posted: %', v_result;

    -- C. EVENT 2: Cash Receipt (2000)
    -- Customer (Gives Value/Credit) --> Cash Account (Receives Value/Debit)
    -- From: Customer (Party) -> To: Cash (Account)
    
    SELECT create_manage_transaction(
        'receipt',                      -- Transaction Type
        'customer', v_cust_id,          -- FROM: Customer Party (Credit AR)
        'account', v_cash_acct_id,      -- TO: Cash Account (Debit Cash)
        2000,                           -- Amount
        'Seed Cash Receipt via RPC',    -- Narration
        CURRENT_DATE                    -- Date
    ) INTO v_result;
    
    RAISE NOTICE 'Receipt Posted: %', v_result;

END $$;

RAISE NOTICE '✅ SEED DATA CONFIRMED VIA RPC.';
COMMIT;

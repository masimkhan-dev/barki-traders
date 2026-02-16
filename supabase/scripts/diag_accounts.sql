DO $$
DECLARE
    r RECORD;
BEGIN
    RAISE NOTICE '--- ACCOUNTS AUDIT ---';
    FOR r IN (SELECT id, code, name, slug, account_type FROM accounts WHERE name ILIKE '%Receivable%' OR name ILIKE '%Payable%' OR slug IN ('ar', 'ap')) LOOP
        RAISE NOTICE 'ID: %, Code: %, Name: %, Slug: %, Type: %', r.id, r.code, r.name, r.slug, r.account_type;
    END LOOP;

    RAISE NOTICE '--- LEDGER BALANCE BY ACCOUNT ---';
    FOR r IN (
        SELECT a.name, a.slug, SUM(le.debit_amount - le.credit_amount) as balance
        FROM accounts a
        JOIN ledger_entries le ON le.account_id = a.id
        WHERE a.account_type = 'asset'
        GROUP BY a.id, a.name, a.slug
        HAVING SUM(le.debit_amount - le.credit_amount) <> 0
    ) LOOP
        RAISE NOTICE 'Account: % (Slug: %), Balance: %', r.name, r.slug, r.balance;
    END LOOP;
END $$;

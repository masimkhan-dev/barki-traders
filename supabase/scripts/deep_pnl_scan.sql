DO $$
DECLARE
    r RECORD;
BEGIN
    RAISE NOTICE '--- DP SCAN: ACCOUNTS WITH BALANCES ---';
    FOR r IN (
        SELECT 
            a.name, 
            a.account_type, 
            a.slug, 
            SUM(le.debit_amount - le.credit_amount) as net_diff
        FROM accounts a
        JOIN ledger_entries le ON le.account_id = a.id
        WHERE le.is_reversed = false
        GROUP BY a.id, a.name, a.account_type, a.slug
        HAVING SUM(le.debit_amount - le.credit_amount) <> 0
    ) LOOP
        RAISE NOTICE 'Account: % | Type: % | Slug: % | Net: %', 
            r.name, r.account_type, r.slug, r.net_diff;
    END LOOP;
END $$;

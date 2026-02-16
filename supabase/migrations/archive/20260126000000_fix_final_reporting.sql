BEGIN;

-- 1. LEGITIMIZE THE SUSPENSE ACCOUNT
UPDATE ledger_entries
SET account_id = (SELECT id FROM accounts WHERE code = '3000') 
WHERE account_id IN (SELECT id FROM accounts WHERE code = '9999');

-- Delete the temporary suspense account
DELETE FROM accounts WHERE code = '9999';

-- 2. CREATE STANDARD TRIAL BALANCE FUNCTION
CREATE OR REPLACE FUNCTION get_trial_balance_final(p_date DATE)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    account_type TEXT,
    debit NUMERIC,
    credit NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    -- GL Accounts
    SELECT 
        a.code,
        a.name,
        a.account_type::TEXT,
        CASE WHEN SUM(le.debit_amount - le.credit_amount) > 0 THEN SUM(le.debit_amount - le.credit_amount) ELSE 0 END,
        CASE WHEN SUM(le.credit_amount - le.debit_amount) > 0 THEN SUM(le.credit_amount - le.debit_amount) ELSE 0 END
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE le.posting_date <= p_date
      AND COALESCE(le.is_reversed, false) = false
    GROUP BY a.code, a.name, a.account_type
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0
    
    UNION ALL
    
    -- Sub-ledger (Parties)
    SELECT 
        CASE WHEN p.type = 'customer' THEN 'CUST-' || p.name ELSE 'SUP-' || p.name END,
        p.name,
        'party',
        CASE WHEN (COALESCE(p.opening_balance, 0) + SUM(le.debit_amount - le.credit_amount)) > 0 
             THEN (COALESCE(p.opening_balance, 0) + SUM(le.debit_amount - le.credit_amount)) ELSE 0 END,
        CASE WHEN (COALESCE(p.opening_balance, 0) + SUM(le.debit_amount - le.credit_amount)) < 0 
             THEN ABS(COALESCE(p.opening_balance, 0) + SUM(le.debit_amount - le.credit_amount)) ELSE 0 END
    FROM parties p
    LEFT JOIN ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date AND COALESCE(le.is_reversed, false) = false
    GROUP BY p.name, p.type, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + SUM(le.debit_amount - le.credit_amount)) <> 0
    
    ORDER BY 1;
END;
$$ LANGUAGE plpgsql STABLE;


-- 3. CREATE STANDARD BALANCE SHEET FUNCTION (Fixed UNIONs)
CREATE OR REPLACE FUNCTION get_balance_sheet_final(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE
    v_net_profit NUMERIC;
BEGIN
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_net_profit
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date <= p_date
      AND COALESCE(le.is_reversed, false) = false;

    RETURN QUERY
    -- 1. Current Assets
    SELECT 'ASSETS'::TEXT, 'Current Assets'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset' 
      AND le.posting_date <= p_date 
      AND COALESCE(le.is_reversed, false) = false
    GROUP BY a.name
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL
    -- 2. Receivables
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT,
           COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM parties p
    LEFT JOIN ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date AND COALESCE(le.is_reversed, false) = false
    GROUP BY p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) > 0

    UNION ALL
    -- 3. Liabilities
    SELECT 'LIABILITIES'::TEXT, 'Current Liabilities'::TEXT, p.name::TEXT,
           ABS(COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0))
    FROM parties p
    LEFT JOIN ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date AND COALESCE(le.is_reversed, false) = false
    GROUP BY p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) < 0

    UNION ALL
    -- 4. Owner's Equity
    SELECT 'EQUITY'::TEXT, 'Owner''s Equity'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'equity'
      AND le.posting_date <= p_date 
      AND COALESCE(le.is_reversed, false) = false
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL
    -- 5. Retained Earnings
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Net Profit / (Loss)'::TEXT, v_net_profit;
END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;

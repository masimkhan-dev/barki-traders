CREATE OR REPLACE FUNCTION get_financial_position(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
DECLARE
    v_net_profit NUMERIC;
BEGIN
    -- 1. Calculate Net Profit (Income - Expense)
    -- Income (Cr) - Expense (Dr)
    -- Result: Positive = Profit, Negative = Loss
    SELECT COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    INTO v_net_profit
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('income', 'expense')
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false);

    RETURN QUERY
    -- 2. ASSETS (System Accounts)
    -- Cash, Bank, Inventory, Fixed Assets
    -- Formula: Dr - Cr
    SELECT 'ASSETS'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'asset'
      AND a.slug NOT IN ('ar', 'ap') -- Exclude control accounts if they exist, to avoid duplication with Parties
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL

    -- 3. ASSETS (Customers - Receivables)
    -- Parties of type 'customer' are Assets
    -- Formula: Dr (Receivable) - Cr (Received)
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, (p.name || ' (Customer)')::TEXT,
           COALESCE(SUM(le.debit_amount - le.credit_amount), 0)
    FROM parties p
    JOIN ledger_entries le ON le.party_id = p.id
    WHERE p.type = 'customer'
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.name, p.type
    HAVING SUM(le.debit_amount - le.credit_amount) <> 0

    UNION ALL

    -- 4. LIABILITIES (System Accounts)
    -- Loans, Tax Payable, etc.
    -- Formula: Cr - Dr
    SELECT 'LIABILITIES'::TEXT, 'Current'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND a.slug NOT IN ('ar', 'ap')
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 5. LIABILITIES (Suppliers - Payables)
    -- Parties of type 'supplier' are Liabilities
    -- Formula: Cr (Payable) - Dr (Paid)
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, (p.name || ' (Supplier)')::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM parties p
    JOIN ledger_entries le ON le.party_id = p.id
    WHERE p.type = 'supplier'
      AND le.posting_date <= p_date
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY p.name, p.type
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 6. EQUITY (System Accounts)
    -- Capital, etc. (Excluding Retained Earnings which is calc'd below)
    -- Formula: Cr - Dr
    SELECT 'EQUITY'::TEXT, 'Owner Capital'::TEXT, a.name::TEXT,
           COALESCE(SUM(le.credit_amount - le.debit_amount), 0)
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE (a.account_type = 'equity' OR a.code = '3000') 
      AND le.posting_date <= p_date 
      AND (le.is_reversed IS NULL OR le.is_reversed = false)
    GROUP BY a.name
    HAVING SUM(le.credit_amount - le.debit_amount) <> 0

    UNION ALL

    -- 7. RETAINED EARNINGS (Calculated Net Profit)
    SELECT 'EQUITY'::TEXT, 'Retained Earnings'::TEXT, 'Net Profit'::TEXT, v_net_profit;
END;
$$ LANGUAGE plpgsql STABLE;

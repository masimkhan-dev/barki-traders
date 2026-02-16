-- MASTER RESTORATION & REPORTS FIX (V14)
-- Objective: Fix 400 (Missing Column) and 404 (Missing RPCs) for Trial Balance and Balance Sheet.

BEGIN;

-- 1. FIX: Missing 'is_reversed' column for Roznamcha
DO $$ 
BEGIN 
    IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='ledger_entries' AND COLUMN_NAME='is_reversed') THEN
        ALTER TABLE public.ledger_entries ADD COLUMN is_reversed BOOLEAN DEFAULT false;
    END IF;
END $$;

-- 2. RESTORE: Trial Balance v2 (Munshi Standard)
-- This RPC calculates Opening, Total Debit, Total Credit, and Closing for every moving account.
CREATE OR REPLACE FUNCTION get_trial_balance_v2(p_start_date DATE, p_end_date DATE)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    opening_balance NUMERIC,
    debit_total NUMERIC,
    credit_total NUMERIC,
    closing_balance NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    WITH base_data AS (
        -- Combine GL Accounts and Parties into a unified Trial Balance
        SELECT 
            a.code as a_code, 
            a.name as a_name,
            -- Opening from GL accounts
            COALESCE((
                SELECT SUM(le_p.debit_amount - le_p.credit_amount) 
                FROM ledger_entries le_p 
                WHERE le_p.account_id = a.id AND le_p.posting_date < p_start_date
            ), 0) as op,
            -- Movement in range
            COALESCE((
                SELECT SUM(le_m.debit_amount) 
                FROM ledger_entries le_m 
                WHERE le_m.account_id = a.id AND le_m.posting_date BETWEEN p_start_date AND p_end_date
            ), 0) as dr,
            COALESCE((
                SELECT SUM(le_m.credit_amount) 
                FROM ledger_entries le_m 
                WHERE le_m.account_id = a.id AND le_m.posting_date BETWEEN p_start_date AND p_end_date
            ), 0) as cr
        FROM accounts a
        WHERE a.code NOT IN ('1100', '2000') -- Skip control accounts, we will add parties instead
        
        UNION ALL
        
        -- Add Parties (The "Individual Khatas")
        SELECT 
            CASE WHEN p.type = 'supplier' THEN 'SUP-' || p.name ELSE 'CUST-' || p.name END as a_code,
            p.name as a_name,
            -- Party opening + ledger before start
            COALESCE(p.opening_balance, 0) + COALESCE((
                SELECT SUM(le_p.debit_amount - le_p.credit_amount) 
                FROM ledger_entries le_p 
                WHERE le_p.party_id = p.id AND le_p.posting_date < p_start_date
            ), 0) as op,
            COALESCE((
                SELECT SUM(le_m.debit_amount) 
                FROM ledger_entries le_m 
                WHERE le_m.party_id = p.id AND le_m.posting_date BETWEEN p_start_date AND p_end_date
            ), 0) as dr,
            COALESCE((
                SELECT SUM(le_m.credit_amount) 
                FROM ledger_entries le_m 
                WHERE le_m.party_id = p.id AND le_m.posting_date BETWEEN p_start_date AND p_end_date
            ), 0) as cr
        FROM parties p
    )
    SELECT 
        a_code, 
        a_name, 
        op as opening_balance, 
        dr as debit_total, 
        cr as credit_total, 
        (op + dr - cr) as closing_balance
    FROM base_data
    WHERE (ABS(op) > 0 OR dr > 0 OR cr > 0)
    ORDER BY a_code;
END; $$ LANGUAGE plpgsql;

-- 3. RESTORE: Balance Sheet (Wealth Statement)
CREATE OR REPLACE FUNCTION get_balance_sheet(p_date DATE)
RETURNS TABLE (
    category TEXT,
    sub_category TEXT,
    account_name TEXT,
    balance NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    -- Assets
    SELECT 'ASSETS'::TEXT, a.account_type::TEXT, a.name::TEXT, 
           SUM(le.debit_amount - le.credit_amount) as bal
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type IN ('asset', 'inventory', 'cash')
      AND le.posting_date <= p_date
      AND a.code NOT IN ('1100') -- Handle receivables via parties
    GROUP BY a.account_type, a.name
    
    UNION ALL
    
    -- Receivables from Parties
    SELECT 'ASSETS'::TEXT, 'Receivables'::TEXT, p.name::TEXT,
           COALESCE(p.opening_balance, 0) + SUM(le.debit_amount - le.credit_amount)
    FROM parties p
    LEFT JOIN ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
    WHERE p.type = 'customer'
    GROUP BY p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) > 0

    UNION ALL
    
    -- Liabilities
    SELECT 'LIABILITIES'::TEXT, a.account_type::TEXT, a.name::TEXT,
           ABS(SUM(le.debit_amount - le.credit_amount)) as bal
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'liability'
      AND le.posting_date <= p_date
      AND a.code NOT IN ('2000') -- Handle payables via parties
    GROUP BY a.account_type, a.name

    UNION ALL
    
    -- Payables to Parties (Suppliers)
    SELECT 'LIABILITIES'::TEXT, 'Payables'::TEXT, p.name::TEXT,
           ABS(COALESCE(p.opening_balance, 0) + SUM(le.debit_amount - le.credit_amount))
    FROM parties p
    LEFT JOIN ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_date
    WHERE p.type = 'supplier'
    GROUP BY p.name, p.opening_balance
    HAVING (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) < 0

    UNION ALL

    -- Equity & Retained Earnings
    SELECT 'EQUITY'::TEXT, 'Capital'::TEXT, a.name::TEXT,
           ABS(SUM(le.debit_amount - le.credit_amount)) as bal
    FROM accounts a
    JOIN ledger_entries le ON le.account_id = a.id
    WHERE a.account_type = 'equity'
      AND le.posting_date <= p_date
    GROUP BY a.name;
END; $$ LANGUAGE plpgsql;

-- 4. UTILITY: Report Logger (Prevents 404 in Trial Balance log call)
CREATE TABLE IF NOT EXISTS public.report_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_name TEXT,
    filters JSONB,
    generated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now())
);

CREATE OR REPLACE FUNCTION log_report_generation(p_report_name TEXT, p_filters JSONB)
RETURNS VOID AS $$
BEGIN
    INSERT INTO public.report_logs (report_name, filters)
    VALUES (p_report_name, p_filters);
END; $$ LANGUAGE plpgsql;

COMMIT;
NOTIFY pgrst, 'reload config';

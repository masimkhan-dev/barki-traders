-- ==========================================
-- 🚀 V11 EMERGENCY RECONCILIATION & REPAIR
-- ==========================================
-- Objective 1: Fix Account Slugs (Root Cause of missing Ledger entries)
-- Objective 2: Audit-Grade Trial Balance (Include Party Opening Balances)
-- Objective 3: Fix Market Position Report (Prevent skipping entries)

BEGIN;

--------------------------------------------------------------------------------
-- 1. ACCOUNT SLUG RECONCILIATION
--------------------------------------------------------------------------------
-- Ensure standard slugs exist for all core accounts
UPDATE public.accounts SET slug = 'cash' WHERE code = '1000' OR name ILIKE 'Cash on Hand';
UPDATE public.accounts SET slug = 'bank' WHERE code = '1010' OR name ILIKE 'Bank Account%';
UPDATE public.accounts SET slug = 'ar' WHERE code = '1100' OR name ILIKE 'Accounts Receivable' OR name ILIKE 'Receivables%';
UPDATE public.accounts SET slug = 'ap' WHERE code = '2000' OR code = '2100' OR name ILIKE 'Accounts Payable' OR name ILIKE 'Payables%';
UPDATE public.accounts SET slug = 'inventory' WHERE code = '1200' OR name ILIKE '%Inventory%' OR name ILIKE 'Fuel Purchase%';
UPDATE public.accounts SET slug = 'sales_revenue' WHERE code = '4000' OR name ILIKE 'Sales Revenue' OR name ILIKE 'Revenue%';
UPDATE public.accounts SET slug = 'cogs' WHERE code = '5000' OR code = '4100' OR name ILIKE 'Cost of Goods Sold' OR name ILIKE 'Purchase Cost%';
UPDATE public.accounts SET slug = 'capital' WHERE code = '3000' OR code = '3010' OR name ILIKE '%Capital%';

-- Ensure all accounts used in V11 triggers have slugs
UPDATE public.accounts SET slug = 'inventory' WHERE name ILIKE '%Fuel Purchase Cost%' AND slug IS NULL;
UPDATE public.accounts SET slug = 'cogs' WHERE name ILIKE '%Cost of Goods Sold%' AND slug IS NULL;

--------------------------------------------------------------------------------
-- 2. REPAIR ORPHANED LEDGER ENTRIES
--------------------------------------------------------------------------------
-- If any ledger entries were created with NULL account_id due to previous trigger failures
UPDATE public.ledger_entries le
SET account_id = a.id
FROM public.accounts a
WHERE le.account_id IS NULL
  AND (
    (le.voucher_type = 'purchase' AND a.slug = 'inventory' AND le.debit_amount > 0) OR
    (le.voucher_type = 'purchase' AND a.slug = 'ap' AND le.credit_amount > 0) OR
    (le.voucher_type = 'sale' AND a.slug = 'ar' AND le.debit_amount > 0) OR
    (le.voucher_type = 'sale' AND a.slug = 'sales_revenue' AND le.credit_amount > 0)
  );

--------------------------------------------------------------------------------
-- 3. AUDIT-GRADE TRIAL BALANCE V3 (Correctly Handle Party Openings)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_trial_balance_v2(
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS TABLE (
    account_code TEXT,
    account_name TEXT,
    account_type TEXT,
    opening_balance NUMERIC,
    debit_total NUMERIC,
    credit_total NUMERIC,
    debit_balance NUMERIC,
    credit_balance NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    WITH all_entities AS (
        -- SYSTEM ACCOUNTS
        SELECT 
            a.id as entity_id,
            'account' as entity_type,
            a.code::TEXT as ac,
            a.name::TEXT as an,
            a.account_type::TEXT as at,
            0::NUMERIC as base_opening -- Accounts table opening is usually handled via opening entries in ledger
        FROM public.accounts a
        WHERE a.is_active = true 
          AND a.slug NOT IN ('ar', 'ap')

        UNION ALL

        -- PARTY ACCOUNTS
        SELECT 
            p.id as entity_id,
            'party' as entity_type,
            (CASE WHEN p.type='customer' THEN '1100-' ELSE '2100-' END || p.id)::TEXT as ac,
            (p.name || ' (' || UPPER(LEFT(p.type, 1)) || ')')::TEXT as an,
            (CASE WHEN p.type='customer' THEN 'asset' ELSE 'liability' END)::TEXT as at,
            COALESCE(p.opening_balance, 0) as base_opening
        FROM public.parties p
        WHERE p.is_active = true 
    ),
    ledger_summary AS (
        -- Summarize ledger activity per entity
        SELECT 
            ae.entity_id,
            ae.entity_type,
            SUM(CASE WHEN (p_start_date IS NOT NULL AND le.posting_date < p_start_date) THEN le.debit_amount - le.credit_amount ELSE 0 END) as ledger_opening,
            SUM(CASE WHEN (p_start_date IS NULL OR le.posting_date >= p_start_date) AND (p_end_date IS NULL OR le.posting_date <= p_end_date) THEN le.debit_amount ELSE 0 END) as period_dr,
            SUM(CASE WHEN (p_start_date IS NULL OR le.posting_date >= p_start_date) AND (p_end_date IS NULL OR le.posting_date <= p_end_date) THEN le.credit_amount ELSE 0 END) as period_cr
        FROM all_entities ae
        LEFT JOIN public.ledger_entries le ON 
            (ae.entity_type = 'account' AND le.account_id = ae.entity_id)
            OR (ae.entity_type = 'party' AND le.party_id = ae.entity_id)
        WHERE (le.is_reversed IS NULL OR le.is_reversed = false)
        GROUP BY ae.entity_id, ae.entity_type
    ),
    results AS (
        SELECT 
            ae.ac as account_code,
            ae.an as account_name,
            ae.at as account_type,
            (ae.base_opening + COALESCE(ls.ledger_opening, 0))::NUMERIC as opening_balance,
            COALESCE(ls.period_dr, 0)::NUMERIC as debit_total,
            COALESCE(ls.period_cr, 0)::NUMERIC as credit_total
        FROM all_entities ae
        LEFT JOIN ledger_summary ls ON ae.entity_id = ls.entity_id AND ae.entity_type = ls.entity_type
    ),
    final_calc AS (
        SELECT 
            r.*,
            (r.opening_balance + r.debit_total - r.credit_total) as closing
        FROM results r
    )
    SELECT 
        f.account_code,
        f.account_name,
        f.account_type,
        f.opening_balance,
        f.debit_total,
        f.credit_total,
        CASE WHEN f.closing > 0 THEN f.closing ELSE 0 END as debit_balance,
        CASE WHEN f.closing < 0 THEN ABS(f.closing) ELSE 0 END as credit_balance
    FROM final_calc f
    WHERE f.debit_total != 0 OR f.credit_total != 0 OR f.opening_balance != 0
    ORDER BY f.account_code;
END;
$$;

--------------------------------------------------------------------------------
-- 4. FIX MARKET POSITION REPORT (Resilient Join)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_market_position_report(p_as_of_date DATE)
RETURNS TABLE (
    party_id UUID,
    party_name TEXT,
    party_type TEXT,
    receivable_balance NUMERIC,
    payable_balance NUMERIC,
    last_transaction_date DATE
) AS $$
BEGIN
    RETURN QUERY
    WITH PartyBalances AS (
        SELECT 
            p.id as pid,
            p.name as pname,
            p.type as ptype,
            (COALESCE(p.opening_balance, 0) + COALESCE(SUM(le.debit_amount - le.credit_amount), 0)) as net_balance,
            MAX(le.posting_date) as last_tx
        FROM public.parties p
        LEFT JOIN public.ledger_entries le ON le.party_id = p.id AND le.posting_date <= p_as_of_date
          AND (le.is_reversed IS NULL OR le.is_reversed = false)
          -- Filter: Only balance sheet items (Assets/Liabilities) affecting parties.
          -- If account_id is NULL, we still count it because it has a party_id.
          AND (
              le.account_id IS NULL 
              OR le.account_id IN (SELECT id FROM public.accounts WHERE account_type NOT IN ('income', 'expense'))
          )
        GROUP BY p.id, p.name, p.type, p.opening_balance
    )
    SELECT 
        pid,
        pname,
        ptype::text,
        CASE WHEN net_balance > 0 THEN net_balance ELSE 0 END as receivable_balance,
        CASE WHEN net_balance < 0 THEN ABS(net_balance) ELSE 0 END as payable_balance,
        last_tx
    FROM PartyBalances
    WHERE net_balance != 0
    ORDER BY pname ASC;
END; $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMIT;

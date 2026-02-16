-- NEW RPC for Daily Summary Dashboard
CREATE OR REPLACE FUNCTION get_daily_summary(target_date DATE)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    result json;
    v_total_sales numeric;
    v_total_purchases numeric;
    v_cash_in numeric;
    v_cash_out numeric;
BEGIN
    -- Total Sales (from Sales table for easy retrieval, though Ledger is preferred source of truth, Sales is consistent)
    -- Actually, let's use LE to be consistent with "Ledger Driven" requirement.
    -- Sales = Credit on 4000
    SELECT COALESCE(SUM(credit_amount), 0)
    INTO v_total_sales
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE a.code = '4000' AND le.posting_date = target_date;

    -- Purchases = Debit on 5000 (Wait, 5000 is COGS. Purchases usually go to Inventory 1200 or Expense if direct)
    -- In this system, Purchases -> Inventory (Asset).
    -- So we look for Debits to Inventory (1200) LINKED to a Purchase?
    -- Actually, simpler: Purchases table totals.
    SELECT COALESCE(SUM(total_amount), 0)
    INTO v_total_purchases
    FROM purchases
    WHERE purchase_date = target_date;

    -- Cash In: Debits to Cash (1000) or Bank (1010)
    SELECT COALESCE(SUM(debit_amount), 0)
    INTO v_cash_in
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE a.code IN ('1000', '1010') AND le.posting_date = target_date;

    -- Cash Out: Credits to Cash (1000) or Bank (1010)
    SELECT COALESCE(SUM(credit_amount), 0)
    INTO v_cash_out
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE a.code IN ('1000', '1010') AND le.posting_date = target_date;

    SELECT json_build_object(
        'total_sales', v_total_sales,
        'total_purchases', v_total_purchases,
        'cash_in', v_cash_in,
        'cash_out', v_cash_out
    ) INTO result;

    RETURN result;
END;
$$;

-- Ensure get_trial_balance defaults to wider range if needed or works as is.
-- (No change needed, it accepts params)

-- Refresh Customer Statement RPC to be robust
DROP FUNCTION IF EXISTS get_customer_ledger_statement(uuid);

CREATE OR REPLACE FUNCTION get_customer_ledger_statement(target_customer_id UUID)
RETURNS TABLE (
    entry_id UUID,
    posting_date DATE,
    voucher_no TEXT,
    voucher_type TEXT,
    narration TEXT,
    debit_amount NUMERIC,
    credit_amount NUMERIC,
    running_balance NUMERIC
) 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        le.id as entry_id,
        le.posting_date,
        le.voucher_no, -- Use ledger entry voucher
        le.voucher_type::text as voucher_type,
        -- Generate a narration
        COALESCE(le.narration, 
            CASE 
                WHEN s.id IS NOT NULL THEN 'Sale - ' || COALESCE(s.notes, '')
                WHEN p.id IS NOT NULL THEN 'Payment - ' || COALESCE(p.payment_method, '')
                ELSE 'Transaction'
            END
        ) as narration,
        le.debit_amount,
        le.credit_amount,
        0::numeric as running_balance -- Client side calculates this
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    LEFT JOIN sales s ON le.reference_type = 'sale' AND le.reference_id = s.id
    LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
    WHERE 
        -- Filter by Account: Must be AR (1100) or Advances (2100)
        a.code IN ('1100', '2100')
        AND (
            -- Linked via Sale
            (s.customer_id = target_customer_id)
            OR 
            -- Linked via Payment (Receipt)
            (p.party_id = target_customer_id AND p.party_type = 'customer')
        )
    ORDER BY le.posting_date ASC, le.created_at ASC;
END;
$$;

-- Refresh Supplier Statement RPC
DROP FUNCTION IF EXISTS get_supplier_ledger_statement(uuid);

CREATE OR REPLACE FUNCTION get_supplier_ledger_statement(target_supplier_id UUID)
RETURNS TABLE (
    entry_id UUID,
    posting_date DATE,
    voucher_no TEXT,
    voucher_type TEXT,
    narration TEXT,
    debit_amount NUMERIC,
    credit_amount NUMERIC,
    running_balance NUMERIC
) 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        le.id as entry_id,
        le.posting_date,
        le.voucher_no,
        le.voucher_type::text as voucher_type,
        COALESCE(le.narration,
            CASE 
                WHEN pur.id IS NOT NULL THEN 'Purchase - ' || COALESCE(pur.notes, '')
                WHEN p.id IS NOT NULL THEN 'Payment - ' || COALESCE(p.payment_method, '')
                ELSE 'Transaction'
            END
        ) as narration,
        le.debit_amount,
        le.credit_amount,
        0::numeric as running_balance
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    LEFT JOIN purchases pur ON le.reference_type = 'purchase' AND le.reference_id = pur.id
    LEFT JOIN payments p ON le.reference_type = 'payment' AND le.reference_id = p.id
    WHERE 
        a.code IN ('2000', '1110') -- AP (2000) or Supplier Advances (1110)
        AND (
            (pur.supplier_id = target_supplier_id)
            OR 
            (p.party_id = target_supplier_id AND p.party_type = 'supplier')
        )
    ORDER BY le.posting_date ASC, le.created_at ASC;
END;
$$;

-- V11 MARKET POSITION REPORT (HARDENED - NO FILTER)
-- Purpose: Correct Party-wise Receivables/Payables tracking for Monthly Report.
-- Strategy: Use RAW summation to match Dashboard and Statement accuracy perfectly.

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
        LEFT JOIN (
            SELECT le.* 
            FROM public.ledger_entries le
            JOIN public.accounts a ON le.account_id = a.id
            WHERE a.account_type::TEXT NOT IN ('income', 'expense')
        ) le ON le.party_id = p.id AND le.posting_date <= p_as_of_date
        -- Filter removed: All entries (excluding P&L) must be counted.
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

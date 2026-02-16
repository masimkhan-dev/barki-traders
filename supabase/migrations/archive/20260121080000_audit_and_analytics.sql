-- MASTER REPAIR V10: PRODUCTION-READY FDMS RELOADED
-- Focus: Audit Logs, Security, Overdue Tracking, and Profit/Loss Analytics.

BEGIN;

-- 1. IMMUTABLE AUDIT LOG SYSTEM
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    action TEXT NOT NULL, -- INSERT, UPDATE, DELETE
    old_data JSONB,
    new_data JSONB,
    user_id UUID REFERENCES auth.users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now())
);

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
-- Admin only view for audit logs
CREATE POLICY "Admins can view audit logs" ON audit_logs FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- 2. GENERIC AUDIT TRIGGER FUNCTION
CREATE OR REPLACE FUNCTION public.proc_audit_logger()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO audit_logs (table_name, record_id, action, new_data, user_id)
        VALUES (TG_TABLE_NAME, NEW.id, 'INSERT', to_jsonb(NEW), auth.uid());
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO audit_logs (table_name, record_id, action, old_data, new_data, user_id)
        VALUES (TG_TABLE_NAME, NEW.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW), auth.uid());
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO audit_logs (table_name, record_id, action, old_data, user_id)
        VALUES (TG_TABLE_NAME, OLD.id, 'DELETE', to_jsonb(OLD), auth.uid());
        RETURN OLD;
    END IF;
    RETURN NULL;
END; $$ LANGUAGE plpgsql;

-- Apply Audit to all transaction tables
DROP TRIGGER IF EXISTS trg_audit_sales ON sales;
CREATE TRIGGER trg_audit_sales AFTER INSERT OR UPDATE OR DELETE ON sales FOR EACH ROW EXECUTE FUNCTION proc_audit_logger();

DROP TRIGGER IF EXISTS trg_audit_purchases ON purchases;
CREATE TRIGGER trg_audit_purchases AFTER INSERT OR UPDATE OR DELETE ON purchases FOR EACH ROW EXECUTE FUNCTION proc_audit_logger();

DROP TRIGGER IF EXISTS trg_audit_payments ON payments;
CREATE TRIGGER trg_audit_payments AFTER INSERT OR UPDATE OR DELETE ON payments FOR EACH ROW EXECUTE FUNCTION proc_audit_logger();

-- 3. ENHANCED ANALYTICS (P&L and Overdue)
CREATE OR REPLACE FUNCTION get_dashboard_v10_analytics(p_date DATE)
RETURNS TABLE (
    total_sales NUMERIC, 
    total_purchases NUMERIC, 
    receivables NUMERIC, 
    payables NUMERIC,
    net_profit NUMERIC,
    overdue_count INT
) AS $$
DECLARE v_expenses NUMERIC;
BEGIN
    -- Calculate expenses from ledger
    SELECT COALESCE(SUM(debit_amount - credit_amount), 0) INTO v_expenses
    FROM ledger_entries le
    JOIN accounts a ON le.account_id = a.id
    WHERE a.account_type = 'expense' AND le.posting_date <= p_date;

    RETURN QUERY SELECT 
        (SELECT COALESCE(SUM(total_amount), 0) FROM sales WHERE sale_date = p_date),
        (SELECT COALESCE(SUM(total_amount), 0) FROM purchases WHERE purchase_date = p_date),
        (SELECT COALESCE(SUM(current_balance), 0) FROM parties WHERE current_balance > 0),
        (SELECT COALESCE(SUM(ABS(current_balance)), 0) FROM parties WHERE current_balance < 0),
        -- Simplified Profit: Sales Revenue - Cost of Purchases - Operating Expenses
        (SELECT COALESCE(SUM(total_amount), 0) FROM sales) - 
        (SELECT COALESCE(SUM(total_amount), 0) FROM purchases) - v_expenses,
        -- Overdue: Count of parties with balance > 50,000 who haven't paid in 7 days
        (SELECT COUNT(*)::INT FROM parties p 
         WHERE p.current_balance > 50000 
         AND NOT EXISTS (
             SELECT 1 FROM payments pay 
             WHERE pay.party_id = p.id 
             AND pay.payment_date > (now() - INTERVAL '7 days')
         ))
    ;
END; $$ LANGUAGE plpgsql;

-- 4. RE-STABILIZE LEDGER ENTRY VIEW (For Excel Export / History)
CREATE OR REPLACE VIEW transaction_history AS
SELECT 
    le.id,
    le.posting_date,
    le.voucher_no,
    le.voucher_type,
    a.name as account_name,
    p.name as party_name,
    le.debit_amount,
    le.credit_amount,
    le.narration,
    le.created_at
FROM ledger_entries le
LEFT JOIN accounts a ON le.account_id = a.id
LEFT JOIN parties p ON le.party_id = p.id;

COMMIT;
NOTIFY pgrst, 'reload config';

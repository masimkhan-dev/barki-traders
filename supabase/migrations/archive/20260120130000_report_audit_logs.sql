
-- AUDIT TRAIL FOR REPORTS
BEGIN;

CREATE TABLE IF NOT EXISTS report_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_name TEXT NOT NULL,
    user_id UUID REFERENCES auth.users(id),
    filters JSONB,
    generated_at TIMESTAMPTZ DEFAULT NOW(),
    ip_address TEXT
);

-- Function to log report generation
CREATE OR REPLACE FUNCTION log_report_generation(p_report_name TEXT, p_filters JSONB)
RETURNS VOID AS $$
BEGIN
    INSERT INTO report_logs (report_name, user_id, filters)
    VALUES (p_report_name, auth.uid(), p_filters);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;

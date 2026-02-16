-- V11 AUDIT & RECOVERY VAULT
-- Purpose: Store archived copies of deleted or modified transactions for Super Owner review.

CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name TEXT NOT NULL,
    record_id UUID NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    old_data JSONB,
    new_data JSONB,
    changed_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS for Security
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Only Super Owner (Admin) can view logs
DROP POLICY IF EXISTS "Admins can view audit logs" ON public.audit_logs;
CREATE POLICY "Admins can view audit logs" ON public.audit_logs
    FOR SELECT TO authenticated
    USING (EXISTS (
        SELECT 1 FROM public.user_roles 
        WHERE user_id = auth.uid() AND role = 'admin'
    ));

-- System can insert logs
DROP POLICY IF EXISTS "System can insert audit logs" ON public.audit_logs;
CREATE POLICY "System can insert audit logs" ON public.audit_logs
    FOR INSERT TO authenticated
    WITH CHECK (true);

-- HELPER SCRIPT: Assign 'admin' role to users who have NO role
-- Run this if you are stuck on "Awaiting Role Assignment" screen

BEGIN;

-- Insert 'admin' role for any user who doesn't have a role yet
INSERT INTO public.user_roles (user_id, role)
SELECT id, 'admin'::public.app_role 
FROM auth.users u
WHERE NOT EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = u.id);

COMMIT;

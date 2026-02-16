-- PHASE 26: EMERGENCY ACCESS & AUTH REPAIR (RECURSION-SAFE)
-- MISSION: RESTORE USER ACCESS, FIX 500 ERROR, AND ASSIGN ROLES
-- ---------------------------------------------------------------------------

BEGIN;

-- 1. FIX THE RECURSIVE RLS BLOCK (Break the 500 Error loop)
-- ---------------------------------------------------------------------------
-- Drop all problematic roles policies
DROP POLICY IF EXISTS "Admins can manage roles" ON public.user_roles;
DROP POLICY IF EXISTS "Users can view own role" ON public.user_roles;
DROP POLICY IF EXISTS "Authenticated users can view roles" ON public.user_roles;
DROP POLICY IF EXISTS "Admins can insert roles" ON public.user_roles;
DROP POLICY IF EXISTS "Admins can delete roles" ON public.user_roles;

-- Create a Security Definer function to check roles without triggering RLS recursion
CREATE OR REPLACE FUNCTION public.check_user_is_admin() 
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.user_roles 
    WHERE user_id = auth.uid() AND role = 'admin'
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- Enable RLS (just in case)
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Apply fresh, safe policies
CREATE POLICY "Role View Self" ON public.user_roles
    FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE POLICY "Role Admin Full" ON public.user_roles
    FOR ALL TO authenticated USING (public.check_user_is_admin());


-- 2. RESTORE PROFILES ACCESS
-- ---------------------------------------------------------------------------
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view all profiles" ON public.profiles;
CREATE POLICY "Users can view all profiles" ON public.profiles
    FOR SELECT TO authenticated USING (true);


-- 3. ASSIGN PROVIDED ROLES
-- ---------------------------------------------------------------------------

-- Muhammad Asim Khan (khaniasim24@gmail.com) -> ADMIN
INSERT INTO public.user_roles (user_id, role)
VALUES ('87d993c5-397a-46f2-8b73-5005ee4b57ee', 'admin')
ON CONFLICT (user_id, role) DO NOTHING;

-- khan (masimkhan.dev@gmail.com) -> ACCOUNTANT
INSERT INTO public.user_roles (user_id, role)
VALUES ('aed6558a-3cf5-42f6-8d74-16bab31a56f2', 'accountant')
ON CONFLICT (user_id, role) DO NOTHING;


-- 4. FIX OTHER HARDENING POLICIES (Sync with is_admin() helper)
-- ---------------------------------------------------------------------------
-- The is_admin() function used in Phase 22 might also be recursive if not SECURITY DEFINER.
-- Let's redefine is_admin and is_accountant safely.

CREATE OR REPLACE FUNCTION is_admin() RETURNS BOOLEAN AS $$
  SELECT public.check_user_is_admin();
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_accountant() RETURNS BOOLEAN AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'accountant');
$$ LANGUAGE sql STABLE SECURITY DEFINER;

COMMIT;

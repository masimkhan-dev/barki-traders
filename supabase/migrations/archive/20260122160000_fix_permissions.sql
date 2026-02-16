-- PHASE 7: PERMISSIONS & RLS REPAIR (FIX 403 ERRORS)
-- -----------------------------------------------------
-- This migration ensures that the 'authenticated' user has full access
-- to all necessary tables and can execute the new RPCs.
-- It fixes the "403 Forbidden" errors usually caused by missing Grants or Policies.

BEGIN;

-- 1. GRANT USAGE ON SCHEMA
GRANT USAGE ON SCHEMA public TO postgres, anon, authenticated, service_role;

-- 2. GRANT EXECUTE ON NEW RPCs
GRANT EXECUTE ON FUNCTION public.get_sales_report(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_purchase_report(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_cash_flow_report(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_pnl_statement(DATE, DATE, NUMERIC, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_cash_sale(UUID, UUID, NUMERIC, NUMERIC, NUMERIC, DATE, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_cash_purchase(UUID, UUID, NUMERIC, NUMERIC, NUMERIC, DATE, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_system_health() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_party_statement(UUID, DATE, DATE) TO authenticated;

-- 3. ENSURE RLS POLICIES EXIST (DROP AND RECREATE FOR SAFETY)

-- Helper macro to reset policy
DO $$ 
DECLARE 
    t text; 
    tables text[] := ARRAY[
        'parties', 'sales', 'purchases', 'payments', 
        'ledger_entries', 'accounts', 'fuel_types', 'inventory'
    ];
BEGIN 
    FOREACH t IN ARRAY tables LOOP
        -- Enable RLS just in case
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        
        -- Drop old policies to avoid conflicts
        EXECUTE format('DROP POLICY IF EXISTS "Enable all" ON public.%I', t);
        EXECUTE format('DROP POLICY IF EXISTS "Enable all for authenticated" ON public.%I', t);
        EXECUTE format('DROP POLICY IF EXISTS "Authenticated Access" ON public.%I', t);

        -- Create permissive policy
        EXECUTE format('CREATE POLICY "Authenticated Access" ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
    END LOOP; 
END $$;


-- 4. GRANT TABLE PERMISSIONS (CRUD)
GRANT ALL ON TABLE public.parties TO authenticated;
GRANT ALL ON TABLE public.sales TO authenticated;
GRANT ALL ON TABLE public.purchases TO authenticated;
GRANT ALL ON TABLE public.payments TO authenticated;
GRANT ALL ON TABLE public.ledger_entries TO authenticated;
GRANT ALL ON TABLE public.accounts TO authenticated;
GRANT ALL ON TABLE public.fuel_types TO authenticated;
GRANT ALL ON TABLE public.inventory TO authenticated;


COMMIT;

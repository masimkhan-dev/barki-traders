-- =============================================================================
-- GRANT + schema reload for dashboard analytics RPCs (migration 07)
-- Run AFTER 07_DASHBOARD_ANALYTICS_READONLY.sql
-- =============================================================================

BEGIN;
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_dashboard_sales_purchases_trend(DATE, DATE) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_dashboard_cash_flow_trend(DATE, DATE) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_dashboard_stock_by_fuel() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_dashboard_receivables_payables() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_dashboard_top_customers(INT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_dashboard_top_suppliers(INT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_dashboard_profit_trend(DATE, DATE) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_dashboard_fuel_quantity_sold(DATE, DATE) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
